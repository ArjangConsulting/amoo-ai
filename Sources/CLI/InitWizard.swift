import AmooCore
import Foundation
import StudioProtocol
import SwiftyTerminal

// MARK: - Request

/// Setup inputs for `amoo init`. App artifacts are optional and only used when supplied explicitly.
struct InitRequest: Equatable {
    var platform: Platform?
    var additionalRequests: [Self] = []
    var framework: String?
    /// The platform repository inside an orchestrator, relative to the directory holding `AGENTS.md`.
    var repo: String?
    var appPath: String?
    var appID: String?
    var devices: [String] = []
    var launch: Bool?
    var owner: String?
    var ttlMinutes: Int?
    var readyTimeoutSeconds: Int?
    var out: String?
    var json = false
    var dryRun = false
    var nonInteractive = false
    var assumeYes = false
    /// nil asks (terminal) or skips (headless); true/false from --save / --no-save.
    var save: Bool?
    var agentsFile: String?
    /// AI clients to also install the amoo subagents/skills for (`--client`); `--no-skills` opts out.
    var clients: [AgentClient] = []
    var skills: Bool?

    /// Required inputs still absent, phrased as the flag that supplies each.
    var missing: [String] {
        var flags: [String] = []
        if platform == nil {
            flags.append("--platform ios|android")
        }
        if appID == nil, appPath != nil || launch == true {
            flags.append("--app-id <bundle id or package name>")
        }
        if devices.isEmpty {
            flags.append("--device <simulator UDID | emulator serial> (repeatable)")
        }
        return flags
    }
}

// Keep flag validation together in one linear parser.
// swiftlint:disable:next cyclomatic_complexity function_body_length
func parseInitRequest(_ args: [String]) throws -> InitRequest {
    var flags = EnvFlagReader(args)
    var request = InitRequest()
    if let raw = try flags.value("--platform") {
        guard let platform = Platform(rawValue: raw.lowercased()) else {
            throw EnvCommandParseError.usage("--platform must be ios or android, got '\(raw)'.")
        }
        request.platform = platform
    }
    request.framework = try flags.value("--framework")
    if let framework = request.framework,
       !["native", "react-native", "flutter", "kmp"].contains(framework) {
        throw EnvCommandParseError.usage("--framework must be native, react-native, flutter or kmp.")
    }
    request.repo = try flags.value("--repo")
    if let repo = request.repo {
        guard request.platform != nil else {
            throw EnvCommandParseError.usage("--repo names one platform's repository; add --platform ios|android.")
        }
        guard RepositoryTestProfile.isContainedRelativePath(repo) else {
            throw EnvCommandParseError.usage("--repo must be a relative path inside this repository, got '\(repo)'.")
        }
    }
    request.appPath = try flags.value("--app")
    request.appID = try flags.value("--app-id")
    while let device = try flags.value("--device") {
        guard !device.isEmpty, !request.devices.contains(device) else {
            throw EnvCommandParseError.usage("Device IDs must be nonempty and unique.")
        }
        request.devices.append(device)
    }
    let launch = flags.take("--launch")
    let noLaunch = flags.take("--no-launch")
    guard !(launch && noLaunch) else {
        throw EnvCommandParseError.usage("--launch and --no-launch are mutually exclusive.")
    }
    request.launch = launch ? true : (noLaunch ? false : nil)
    request.owner = try flags.value("--owner")
    request.ttlMinutes = try flags.int("--ttl")
    request.readyTimeoutSeconds = try flags.int("--ready-timeout")
    request.out = try flags.value("--out")
    if try flags.value("--out") != nil {
        throw EnvCommandParseError.usage("--out may be specified only once.")
    }
    request.json = flags.take("--json")
    request.dryRun = flags.take("--dry-run")
    request.nonInteractive = flags.take("--non-interactive")
    request.assumeYes = flags.take("--yes")
    let save = flags.take("--save")
    let noSave = flags.take("--no-save")
    guard !(save && noSave) else {
        throw EnvCommandParseError.usage("--save and --no-save are mutually exclusive.")
    }
    request.save = save ? true : (noSave ? false : nil)
    request.agentsFile = try flags.value("--agents-file")
    while let raw = try flags.value("--client") {
        request
            .clients += try parseAgentList(raw, all: AgentClient.allCases, flag: "--client") {
                AgentClient(rawValue: $0)
            }
    }
    let skills = flags.take("--skills")
    let noSkills = flags.take("--no-skills")
    guard !(skills && noSkills), !(noSkills && !request.clients.isEmpty) else {
        throw EnvCommandParseError.usage("--skills/--no-skills conflict with each other or with --client.")
    }
    request.skills = skills ? true : (noSkills ? false : nil)
    guard !(request.json && (!request.clients.isEmpty || skills)) else {
        throw EnvCommandParseError.usage("--json prints one document; run `amoo agent install --json` for skills.")
    }
    // Anything left over (including env up's --port/--avd/--runtime/--model) is not an init option.
    try flags.finish()
    return request
}

// MARK: - Wizard

enum InitWizardError: Error, Equatable {
    case cancelled
}

/// One project-local connection file shared by both platforms and repeated setup runs.
func defaultInitManifestPath(
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
) -> String {
    workingDirectory.appendingPathComponent(".amoo.json").path
}

/// Resolves `~` and relative paths against the working directory, so the manifest and the
/// equivalent command always carry the absolute path `env up` requires.
func absoluteInitPath(_ raw: String, workingDirectory: String = FileManager.default.currentDirectoryPath) -> String {
    let expanded = (raw as NSString).expandingTildeInPath
    let absolute = expanded.hasPrefix("/") ? expanded : workingDirectory + "/" + expanded
    return URL(fileURLWithPath: absolute).standardizedFileURL.path
}

/// One question per method, so each stays readable; every method returns only after an answer and
/// throws `cancelled` when input ends.
private struct InitWizard<Asker: Prompting> {
    let discovery: InitDiscovery
    let prompter: Asker
    let saved: InitSavedLocations?
    let now: Date

    func platforms() throws -> [Platform] {
        guard let index = prompter.choose(
            "Platform",
            options: ["🍎 iOS", "🤖 Android", "🍎 + 🤖 Both"],
            default: 0
        ) else { throw InitWizardError.cancelled }
        return index == 2 ? [.ios, .android] : [index == 0 ? .ios : .android]
    }

    func appID(platform: Platform, appPath: String) throws -> String {
        let detected = discovery.bundleID(appPath, platform) ?? (saved?.appPath == appPath ? saved?.appID : nil)
        while true {
            guard let answer = prompter.ask(
                platform == .ios ? "App bundle identifier" : "App package name",
                default: detected
            ) else { throw InitWizardError.cancelled }
            if !answer.isEmpty {
                return answer
            }
        }
    }

    func devices(platform: Platform) async throws -> [String] {
        let candidates =
            await withSpinner(platform == .ios ? "Loading iOS simulators…" : "Loading Android emulators…") {
                await discovery.devices(platform)
            }
        let sorted = sortedInitDevices(candidates)
        let free = sorted.filter { $0.controlledBy == nil }
        let unavailable = sorted.filter { $0.controlledBy != nil }
        if !unavailable.isEmpty {
            prompter.say("Devices excluded from selection because they already have a reservation:")
            for device in unavailable {
                prompter.say("  \(device.label)")
            }
        }
        guard !free.isEmpty else {
            prompter.say(
                "No \(platform == .ios ? "simulator" : "running emulator") is available. "
                    + (platform == .ios
                        ? "Create one in Xcode, or stop a runtime (`amoo env list`)."
                        : "Start an emulator, then re-run `amoo init`.")
            )
            throw InitWizardError.cancelled
        }
        guard let picked = prompter.chooseMany(
            "Select devices to prepare for testing",
            options: free.map(\.label),
            defaults: []
        ) else { throw InitWizardError.cancelled }
        return picked.map { free[$0].id }
    }

    func launch() throws -> Bool {
        guard let answer = prompter.confirm("Launch the app on each device after installing?", default: true)
        else { throw InitWizardError.cancelled }
        return answer
    }

    /// Which directory holds this platform's app when the root has several candidates (an orchestrator
    /// or a React Native layout). Nil means the root itself is the repository.
    func repo(platform: Platform, root: URL) throws -> String? {
        let found = discovery.repos(root, platform)
        guard !found.isEmpty else { return nil }
        let name = platform == .ios ? "iOS" : "Android"
        guard found.count > 1 else {
            let question = "Found \(found[0])/. Is that the \(name) app's repository?"
            guard let answer = prompter.confirm(question, default: true) else { throw InitWizardError.cancelled }
            return answer ? found[0] : nil
        }
        let options = found + ["This directory (no separate repository)"]
        let remembered = saved?.repoPath.flatMap { found.firstIndex(of: $0) } ?? 0
        let question = "Which directory holds the \(name) app?"
        guard let index = prompter.choose(question, options: options, default: remembered) else {
            throw InitWizardError.cancelled
        }
        return index < found.count ? found[index] : nil
    }

    func manifest(platform: Platform, repo: String? = nil, root: URL) throws -> String {
        let suggested = repo.map {
            portableInitPath(
                root.appendingPathComponent($0, isDirectory: true).appendingPathComponent(".amoo.json").path,
                relativeTo: FileManager.default.currentDirectoryPath
            )
        } ?? ".amoo.json"
        guard let answer = prompter.ask(
            "Save device connection details to (local file; do not commit)",
            default: suggested
        ) else { throw InitWizardError.cancelled }
        return absoluteInitPath(answer)
    }
}

/// Asks only for what the flags left out, defaulting from what the machine can see.
func completeInitRequest(
    _ request: InitRequest,
    discovery: InitDiscovery,
    prompter: some Prompting,
    saved: InitSavedLocations? = nil,
    now: Date = Date(),
    root: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
) async throws -> InitRequest {
    let wizard = InitWizard(discovery: discovery, prompter: prompter, saved: saved, now: now)
    prompter.say("╭─ amoo init ─────────────────────────╮")
    prompter.say("Prepare iOS simulators and Android emulators for testing.")
    prompter.say("Flags already given are kept; answer the rest. No app build is required for setup.\n")

    var result = request
    let platforms = try request.platform.map { [$0] } ?? wizard.platforms()
    if request.framework == nil, request.platform == nil {
        guard let framework = prompter.choose(
            "App framework",
            options: ["Native", "React Native", "Flutter", "Kotlin Multiplatform (KMP)"],
            default: 0
        ) else { throw InitWizardError.cancelled }
        let guidance = [
            "Native: prepare devices now; install the app when starting a test run.",
            "React Native: start Metro when testing if your debug build needs it.",
            "Flutter: prepare devices now; install the app when starting a test run.",
            "KMP: tests run against the iOS or Android host app."
        ]
        result.framework = ["native", "react-native", "flutter", "kmp"][framework]
        prompter.say(guidance[framework])
    }
    let platform = platforms[0]
    let platformWizard = InitWizard(
        discovery: discovery, prompter: prompter, saved: saved?.forPlatform(platform), now: now
    )
    prompter.say("\n\(platform == .ios ? "🍎 iOS — simulators" : "🤖 Android — emulators")")
    result.platform = platform
    if request.repo == nil {
        result.repo = try platformWizard.repo(platform: platform, root: root)
    }
    if result.appID == nil, let appPath = request.appPath {
        result.appID = try platformWizard.appID(platform: platform, appPath: appPath)
    }
    if request.devices.isEmpty {
        result.devices = try await platformWizard.devices(platform: platform)
    }
    result.launch = try request.launch ?? (result.appID == nil ? false : platformWizard.launch())
    result.owner = request.owner ?? "amoo-init"
    result.out = try request.out ?? platformWizard.manifest(platform: platform, repo: result.repo, root: root)
    if platforms.count == 2 {
        var android = request
        android.platform = .android
        android.framework = result.framework
        android.appPath = nil
        android.appID = nil
        android.launch = false
        android.devices = []
        android.repo = nil
        android.out = result.repo == nil ? result.out : request.out
        android.skills = false
        android.clients = []
        result.additionalRequests = try await [completeInitRequest(
            android, discovery: discovery, prompter: prompter, saved: saved, now: now, root: root
        )]
    }
    return result
}
