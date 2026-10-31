import AmooCore
import Foundation

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
