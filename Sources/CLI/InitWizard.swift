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

    func manifest(platform: Platform) throws -> String {
        guard let answer = prompter.ask(
            "Save device connection details to (local file; do not commit)",
            default: ".amoo.json"
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
    now: Date = Date()
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
    if result.appID == nil, let appPath = request.appPath {
        result.appID = try platformWizard.appID(platform: platform, appPath: appPath)
    }
    if request.devices.isEmpty {
        result.devices = try await platformWizard.devices(platform: platform)
    }
    result.launch = try request.launch ?? (result.appID == nil ? false : platformWizard.launch())
    result.owner = request.owner ?? "amoo-init"
    result.out = try request.out ?? platformWizard.manifest(platform: platform)
    if platforms.count == 2 {
        var android = request
        android.platform = .android
        android.framework = result.framework
        android.appPath = nil
        android.appID = nil
        android.launch = false
        android.devices = []
        android.out = result.out
        android.skills = false
        android.clients = []
        result.additionalRequests = try await [completeInitRequest(
            android, discovery: discovery, prompter: prompter, saved: saved, now: now
        )]
    }
    return result
}

// MARK: - Validation and plan

/// One requested device and what is already known to be wrong with it. A problem does not drop the
/// device from the run: `env up` re-checks and reports it as that device's own failed result, so
/// the manifest still has one entry per requested device.
struct InitDeviceCheck: Equatable {
    var id: String
    var candidate: InitDeviceCandidate?
    var problem: String?

    var label: String {
        candidate?.label ?? id
    }
}

/// A fully specified, validated setup: nothing here touches a device until it is run.
struct InitPlan {
    var options: InitOptions
    var devices: [InitDeviceCheck]
    var appSHA256: String?

    var problems: [String] {
        devices.compactMap(\.problem)
    }
}

struct InitPlanError: Error {
    var issues: [String]
}

/// Checks what can be known without starting runtimes. Problems with the artifact doom every device, so they
/// stop the run here (seconds, not a companion build). Problems with one device are recorded and
/// reported per device, so the others still proceed; if every device is unusable nothing starts.
func buildInitPlan(_ request: InitRequest, discovery: InitDiscovery) async -> Result<InitPlan, InitPlanError> {
    var issues = request.missing.map { "Missing \($0)." }
    guard let platform = request.platform, issues.isEmpty
    else { return .failure(InitPlanError(issues: issues)) }

    if let appPath = request.appPath {
        let expectedExtension = platform == .ios ? "app" : "apk"
        if !appPath.hasPrefix("/") {
            issues.append("--app must be an absolute path, got '\(appPath)'.")
        } else if !FileManager.default.fileExists(atPath: appPath) {
            issues.append("No app at \(appPath). Check the explicitly supplied --app path.")
        } else if URL(fileURLWithPath: appPath).pathExtension != expectedExtension {
            issues.append("\(appPath) is not a .\(expectedExtension) for \(platform.rawValue).")
        }
        if issues.isEmpty, let declared = discovery.bundleID(appPath, platform), declared != request.appID {
            issues.append("--app-id \(request.appID ?? "") does not match the app's own identifier \(declared).")
        }
    }

    let candidates = await discovery.devices(platform)
    let checks = request.devices.map { id -> InitDeviceCheck in
        guard let match = candidates.first(where: { $0.id == id }) else {
            return InitDeviceCheck(
                id: id,
                candidate: nil,
                problem: "Device \(id) is not an available \(platform == .ios ? "simulator" : "running emulator") "
                    + "(physical devices are unsupported). Available: "
                    + (candidates.isEmpty ? "none" : candidates.prefix(5).map(\.id).joined(separator: ", ")
                        + (candidates.count > 5 ? " (+\(candidates.count - 5) more)" : "")) + "."
            )
        }
        return InitDeviceCheck(
            id: id,
            candidate: match,
            problem: match.controlledBy.map {
                "Device \(id) is already controlled (\($0)). Init never takes another session's device."
            }
        )
    }
    if checks.allSatisfy({ $0.problem != nil }) {
        issues += checks.compactMap(\.problem)
    }
    guard issues.isEmpty else { return .failure(InitPlanError(issues: issues)) }

    let environment = initEnvironment(for: request, platform: platform)
    return .success(InitPlan(
        options: InitOptions(
            environment: environment,
            devices: request.devices,
            out: request.out,
            framework: request.framework,
            repo: request.repo
        ),
        devices: checks,
        appSHA256: environment.appSHA256
    ))
}

/// The `env up` options every device of this request shares.
private func initEnvironment(for request: InitRequest, platform: Platform) -> EnvUpOptions {
    var environment = EnvUpOptions()
    environment.platform = platform
    environment.appPath = request.appPath
    environment.appID = request.appID
    environment.appSHA256 = request.appPath.flatMap { sha256Hex(ofPath: $0) }
    environment.launch = request.launch ?? false
    environment.owner = request.owner
    environment.ttlMinutes = request.ttlMinutes
    environment.readyTimeoutSeconds = request.readyTimeoutSeconds
    environment.json = request.json
    return environment
}

func shellQuoted(_ value: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
    if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The non-interactive command that reproduces this plan, for agents and CI.
func equivalentInitCommand(_ plan: InitPlan) -> String {
    let environment = plan.options.environment
    var parts = ["amoo", "init", "--platform", environment.platform.rawValue]
    if let appPath = environment.appPath {
        parts += ["--app", shellQuoted(appPath)]
    }
    if let appID = environment.appID {
        parts += ["--app-id", shellQuoted(appID)]
    }
    for device in plan.options.devices {
        parts += ["--device", shellQuoted(device)]
    }
    if let framework = plan.options.framework {
        parts += ["--framework", framework]
    }
    if let repo = plan.options.repo {
        parts += ["--repo", shellQuoted(repo)]
    }
    parts.append(environment.launch ? "--launch" : "--no-launch")
    if let owner = environment.owner {
        parts += ["--owner", shellQuoted(owner)]
    }
    if let ttl = environment.ttlMinutes {
        parts += ["--ttl", String(ttl)]
    }
    if let timeout = environment.readyTimeoutSeconds {
        parts += ["--ready-timeout", String(timeout)]
    }
    if let out = plan.options.out {
        parts += ["--out", shellQuoted(out)]
    }
    parts.append("--non-interactive")
    return parts.joined(separator: " ")
}

func renderInitPlan(_ plan: InitPlan) -> String {
    let environment = plan.options.environment
    let digest = plan.appSHA256.map { String($0.prefix(16)) + "…" } ?? "unavailable"
    var lines = [
        "Plan",
        "  Platform   \(environment.platform.rawValue)",
        "  App        \(environment.appPath ?? "(no artifact supplied)")",
        "  App ID     \(environment.appID ?? "(none)")",
        "  Launch     \(environment.launch ? "yes" : "no")",
        "  Owner      \(environment.owner ?? "(default)")",
        "  Manifest   \(plan.options.out ?? "(none — results on stdout only)")"
    ]
    if environment.appPath != nil {
        lines.insert("  Digest     sha256 \(digest) (same artifact for every device)", at: 3)
    }
    for (index, device) in plan.devices.enumerated() {
        lines.append("  \(index == 0 ? "Devices   " : "          ") \(device.label)")
        if let problem = device.problem {
            lines.append("             ! \(problem) It will be reported as failed.")
        }
    }
    lines.append("")
    lines.append("Equivalent command:")
    lines.append("  \(equivalentInitCommand(plan))")
    return lines.joined(separator: "\n")
}

struct InitPlanReport: Encodable {
    var schemaVersion = 1
    var ok: Bool
    var dryRun = true
    var framework: String?
    var platform: String
    var app: EnvAppReport
    var devices: [Device]
    var launch: Bool
    var out: String?
    var command: String

    struct Device: Encodable {
        var id: String
        var name: String?
        var problem: String?
    }

    init(_ plan: InitPlan) {
        let environment = plan.options.environment
        platform = environment.platform.rawValue
        framework = plan.options.framework
        app = EnvAppReport(
            id: environment.appID,
            path: environment.appPath,
            sha256: plan.appSHA256,
            installed: false,
            launched: false
        )
        ok = plan.problems.isEmpty
        devices = plan.devices.map { Device(id: $0.id, name: $0.candidate?.name, problem: $0.problem) }
        launch = environment.launch
        out = plan.options.out
        command = equivalentInitCommand(plan)
    }
}
