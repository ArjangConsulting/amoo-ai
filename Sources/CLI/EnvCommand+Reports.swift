import AmooCore

struct EnvDeviceReport: Codable, Equatable {
    var id: String
    var name: String?
    var os: String?
    var avd: String?
    var bootedByEnv: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, os, avd
        case bootedByEnv = "booted_by_env"
    }
}

struct EnvAppReport: Codable, Equatable {
    var id: String?
    var path: String?
    var sha256: String?
    var installed: Bool
    var launched: Bool
    var launch: AppLaunchReceipt?
    var foregroundVerified: Bool?
    var semanticReadiness: String?
    var renderReadiness: String?

    enum CodingKeys: String, CodingKey {
        case id, path, sha256, installed, launched, launch
        case foregroundVerified = "foreground_verified"
        case semanticReadiness = "semantic_readiness"
        case renderReadiness = "render_readiness"
    }
}

/// Where `env up` spent its time, in milliseconds.
struct EnvUpTimings: Codable, Equatable {
    /// Resolving the device, including a boot when `device.booted_by_env` is true.
    var device: Int?
    /// From spawning `amoo companion start` until the companion answered gRPC; `companion.phases`
    /// breaks it down.
    var companion: Int?
    /// Installing and launching the app, when `--app` / `--app-id` asked for it.
    var app: Int?
    var total: Int
}

/// What the companion start did, read from the phases the child process recorded.
struct EnvCompanionReport: Codable, Equatable {
    /// `built` (compiled now), `cached` (an earlier build of the same sources), `prebuilt`
    /// (bundled with the distribution), or `nil` when a running companion was reused.
    var build: String?
    /// Android: `installed` when either companion APK was (re)installed, `reused` when the device
    /// already held both. iOS has no separate step: xcodebuild installs the runner during `launch`.
    var install: String?
    /// `reused` (a companion was already serving the port) or `launched`.
    var runner: String?
    var phases: [CompanionStartPhase]
    /// Which build the start used and what the device held; nil when a running companion was reused.
    var buildIdentity: CompanionBuildIdentity?

    enum CodingKeys: String, CodingKey {
        case build, install, runner, phases
        case buildIdentity = "build_identity"
    }

    init(phases: [CompanionStartPhase], buildIdentity: CompanionBuildIdentity? = nil) {
        self.phases = phases
        self.buildIdentity = buildIdentity
        build = phases.last { $0.name == "build" }?.outcome
        let installs = phases.filter { $0.name.hasPrefix("install.") }
        install = installs.isEmpty ? nil : installs.contains { $0.outcome == "installed" } ? "installed" : "reused"
        runner = phases.contains { $0.name == "runner" } ? "reused"
            : phases.contains { $0.name == "launch" } ? "launched" : nil
    }
}

struct EnvUpReport: Codable {
    var ok: Bool
    var runtimeID: String?
    var platform: String
    var device: EnvDeviceReport?
    var port: Int?
    var companionPID: Int32?
    var app: EnvAppReport?
    var log: String?
    var amooVersion = AmooBuildInfo.current.version
    var amooCommit = AmooBuildInfo.current.sourceCommit
    var error: String?
    var state: DeviceRuntimeState?
    var recovered: Bool?
    var recoveryMilliseconds: Int?
    var companion: EnvCompanionReport?
    var timings: EnvUpTimings?

    enum CodingKeys: String, CodingKey {
        case ok, state, platform, device, port, app, log, error, recovered, companion
        case timings = "timings_ms"
        case recoveryMilliseconds = "recovery_ms"
        case runtimeID = "runtime_id"
        case companionPID = "companion_pid"
        case amooVersion = "amoo_version"
        case amooCommit = "amoo_commit"
    }

    var humanSummary: String {
        guard ok, let runtimeID, let device, let port else {
            return "env up failed: \(error ?? "unknown error")" + (log.map { "\nLog: \($0)" } ?? "")
        }
        var lines = [
            "amoo is running on \(device.name ?? device.id).",
            "Companion listening on port \(port)",
            "Runtime ID: \(runtimeID)",
            "Use it: export AMOO_RUNTIME_ID=\(runtimeID)  (or pass --runtime-id \(runtimeID))",
            "Stop: amoo env down --runtime-id \(runtimeID)"
        ]
        if let identity = companion?.buildIdentity {
            lines.append(identity.summary)
        }
        if let app {
            lines.append("App \(app.id ?? app.path ?? "?"): installed=\(app.installed) launched=\(app.launched)")
        }
        return lines.joined(separator: "\n")
    }
}

extension EnvUpReport {
    mutating func prepareApp(_ options: EnvUpOptions) {
        guard options.appID != nil || options.appPath != nil else { return }
        app = EnvAppReport(
            id: options.appID,
            path: options.appPath,
            sha256: options.appSHA256 ?? options.appPath.flatMap { sha256Hex(ofPath: $0) },
            installed: false,
            launched: false
        )
    }
}
