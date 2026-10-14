import AmooCore
import Foundation

// MARK: - Request

/// Everything `amoo init` can be told up front. `nil`/empty means "not supplied": a terminal
/// session is asked for it, a headless one is refused with the full list of what is missing.
struct InitRequest: Equatable {
    var platform: Platform?
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
        if appPath == nil {
            flags.append("--app <absolute path to the prebuilt .app/.apk>")
        }
        if appID == nil {
            flags.append("--app-id <bundle id or package name>")
        }
        if devices.isEmpty {
            flags.append("--device <simulator UDID | emulator serial> (repeatable)")
        }
        return flags
    }
}

func parseInitRequest(_ args: [String]) throws -> InitRequest {
    var flags = EnvFlagReader(args)
    var request = InitRequest()
    if let raw = try flags.value("--platform") {
        guard let platform = Platform(rawValue: raw.lowercased()) else {
            throw EnvCommandParseError.usage("--platform must be ios or android, got '\(raw)'.")
        }
        request.platform = platform
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

/// Default manifest location: beside the leases it refers to, one file per run so a later init can
/// never overwrite the only record of an earlier run's leases.
func defaultInitManifestPath(
    platform: Platform,
    now: Date,
    directory: String? = nil,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let name = "\(platform.rawValue)-\(formatter.string(from: now)).json"
    if let directory {
        return URL(fileURLWithPath: directory).appendingPathComponent(name).path
    }
    return home.appendingPathComponent(".amoo/init/\(name)").path
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
private struct InitWizard<Prompter: CLIPrompting> {
    let discovery: InitDiscovery
    let prompter: Prompter
    let saved: InitSavedLocations?
    let now: Date
    let fileExists: (String) -> Bool

    func platform() throws -> Platform {
        guard let index = prompter.choose(
            "Platform",
            options: ["iOS simulator", "Android emulator"],
            default: 0
        ) else { throw InitWizardError.cancelled }
        return index == 0 ? .ios : .android
    }

    func appPath(platform: Platform) throws -> String {
        var found = discovery.apps(platform)
        if let remembered = saved?.appPath, saved?.platform ?? platform == platform, fileExists(remembered) {
            prompter.say("AGENTS.md remembers the app at \(remembered).")
            found.removeAll { $0 == remembered }
            found.insert(remembered, at: 0)
        }
        if found.isEmpty {
            prompter.say("No built \(platform == .ios ? ".app" : ".apk") found here or in Xcode's DerivedData.")
        } else {
            guard let index = prompter.choose(
                "Built app (newest first)",
                options: found + ["Enter a different path…"],
                default: 0
            ) else { throw InitWizardError.cancelled }
            if index < found.count {
                return found[index]
            }
        }
        while true {
            guard let answer = prompter.ask(
                "Path to the prebuilt \(platform == .ios ? ".app (simulator build)" : ".apk")",
                default: nil
            ) else { throw InitWizardError.cancelled }
            let path = absoluteInitPath(answer)
            if !answer.isEmpty, fileExists(path) {
                return path
            }
            prompter.say("Not found: \(path)")
        }
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
        let candidates = await discovery.devices(platform)
        let free = candidates.filter { $0.leasedBy == nil }
        if candidates.count > free.count {
            prompter.say("\(candidates.count - free.count) device(s) are leased by other sessions and are not offered.")
        }
        guard !free.isEmpty else {
            prompter.say(
                "No unleased \(platform == .ios ? "simulator" : "running emulator") is available. "
                    + (platform == .ios
                        ? "Create one in Xcode, or release a lease (`amoo env list`)."
                        : "Start an emulator, then re-run `amoo init`.")
            )
            throw InitWizardError.cancelled
        }
        guard let picked = prompter.chooseMany(
            "Devices to prepare — each gets its own lease, companion and port",
            options: free.map(\.label),
            defaults: [free.firstIndex(where: \.booted) ?? 0]
        ) else { throw InitWizardError.cancelled }
        return picked.map { free[$0].id }
    }

    func launch() throws -> Bool {
        guard let answer = prompter.confirm("Launch the app on each device after installing?", default: true)
        else { throw InitWizardError.cancelled }
        return answer
    }

    func owner() throws -> String {
        guard let answer = prompter.ask("Owner label (shown to anyone refused a leased device)", default: "amoo-init")
        else { throw InitWizardError.cancelled }
        return answer
    }

    func manifest(platform: Platform) throws -> String {
        guard let answer = prompter.ask(
            "Write the manifest to (holds lease credentials; kept private)",
            default: defaultInitManifestPath(platform: platform, now: now, directory: saved?.manifestDirectory)
        ) else { throw InitWizardError.cancelled }
        return absoluteInitPath(answer)
    }
}

/// Asks only for what the flags left out, defaulting from what the machine can see.
func completeInitRequest(
    _ request: InitRequest,
    discovery: InitDiscovery,
    prompter: some CLIPrompting,
    saved: InitSavedLocations? = nil,
    now: Date = Date(),
    fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) async throws -> InitRequest {
    let wizard = InitWizard(discovery: discovery, prompter: prompter, saved: saved, now: now, fileExists: fileExists)
    prompter.say("amoo init — prepare simulators/emulators from one prebuilt app.")
    prompter.say("Flags already given are kept; answer the rest. The app is never rebuilt.\n")

    var result = request
    let platform = try request.platform ?? wizard.platform()
    result.platform = platform
    let appPath = try request.appPath ?? wizard.appPath(platform: platform)
    result.appPath = appPath
    result.appID = try request.appID ?? wizard.appID(platform: platform, appPath: appPath)
    if request.devices.isEmpty {
        result.devices = try await wizard.devices(platform: platform)
    }
    result.launch = try request.launch ?? wizard.launch()
    result.owner = try request.owner ?? wizard.owner()
    result.out = try request.out ?? wizard.manifest(platform: platform)
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

/// Checks what can be known without leasing. Problems with the artifact doom every device, so they
/// stop the run here (seconds, not a companion build). Problems with one device are recorded and
/// reported per device, so the others still proceed; if every device is unusable nothing starts.
func buildInitPlan(_ request: InitRequest, discovery: InitDiscovery) async -> Result<InitPlan, InitPlanError> {
    var issues = request.missing.map { "Missing \($0)." }
    guard let platform = request.platform, let appPath = request.appPath, let appID = request.appID,
          !request.devices.isEmpty
    else { return .failure(InitPlanError(issues: issues)) }

    var isDirectory: ObjCBool = false
    let expectedExtension = platform == .ios ? "app" : "apk"
    if !appPath.hasPrefix("/") {
        issues.append("--app must be an absolute path, got '\(appPath)'.")
    } else if !FileManager.default.fileExists(atPath: appPath, isDirectory: &isDirectory) {
        issues.append("No app at \(appPath). Build it first; init never builds the app.")
    } else if URL(fileURLWithPath: appPath).pathExtension != expectedExtension {
        issues.append("\(appPath) is not a .\(expectedExtension) for \(platform.rawValue).")
    }
    if issues.isEmpty, let declared = discovery.bundleID(appPath, platform), declared != appID {
        issues.append("--app-id \(appID) does not match the app's own identifier \(declared).")
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
            problem: match.leasedBy.map {
                "Device \(id) is already leased (\($0)). Init never takes another session's device."
            }
        )
    }
    if checks.allSatisfy({ $0.problem != nil }) {
        issues += checks.compactMap(\.problem)
    }
    guard issues.isEmpty else { return .failure(InitPlanError(issues: issues)) }

    var environment = EnvUpOptions()
    environment.platform = platform
    environment.appPath = appPath
    environment.appID = appID
    environment.appSHA256 = sha256Hex(ofPath: appPath)
    environment.launch = request.launch ?? false
    environment.owner = request.owner
    environment.ttlMinutes = request.ttlMinutes
    environment.readyTimeoutSeconds = request.readyTimeoutSeconds
    environment.json = request.json
    return .success(InitPlan(
        options: InitOptions(environment: environment, devices: request.devices, out: request.out),
        devices: checks,
        appSHA256: environment.appSHA256
    ))
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
    parts += ["--app", shellQuoted(environment.appPath ?? ""), "--app-id", shellQuoted(environment.appID ?? "")]
    for device in plan.options.devices {
        parts += ["--device", shellQuoted(device)]
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
        "  App        \(environment.appPath ?? "?")",
        "  Digest     sha256 \(digest) (same artifact for every device)",
        "  App ID     \(environment.appID ?? "?")",
        "  Launch     \(environment.launch ? "yes" : "no")",
        "  Owner      \(environment.owner ?? "(default)")",
        "  Manifest   \(plan.options.out ?? "(none — results on stdout only)")"
    ]
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
