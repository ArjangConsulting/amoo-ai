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
    var lease: String?
    var platform: String
    var device: EnvDeviceReport?
    var port: Int?
    var holderPID: Int32?
    var app: EnvAppReport?
    var log: String?
    var amooVersion = AmooBuildInfo.current.version
    var amooCommit = AmooBuildInfo.current.sourceCommit
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, lease, platform, device, port, app, log, error
        case holderPID = "holder_pid"
        case amooVersion = "amoo_version"
        case amooCommit = "amoo_commit"
    }

    var humanSummary: String {
        guard ok, let lease, let device, let port else {
            return "env up failed: \(error ?? "unknown error")" + (log.map { "\nLog: \($0)" } ?? "")
        }
        var lines = [
            "Leased \(device.name ?? device.id) (\(device.id)) as \(lease).",
            "Companion on port \(port) (holder pid \(holderPID.map(String.init) ?? "?"), log \(log ?? "-")).",
            "Use: amoo device --platform \(platform) --device \(device.id) --port \(port) --lease \(lease) <tool>"
        ]
        if let app {
            lines.append("App \(app.id ?? app.path ?? "?"): installed=\(app.installed) launched=\(app.launched)")
        }
        return lines.joined(separator: "\n")
    }
}
