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

    enum CodingKeys: String, CodingKey {
        case ok, state, platform, device, port, app, log, error
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
