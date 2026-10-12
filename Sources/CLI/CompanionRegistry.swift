import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One running `amoo companion start` holder, as recorded for `companion list` / `companion stop`.
struct CompanionRegistration: Codable, Equatable, Sendable {
    var pid: Int32
    var platform: String
    var deviceID: String
    var port: Int
    var appID: String?
    var startedAt: Date
}

/// Files under `~/Library/Application Support/Amoo/companions` (or `AMOO_COMPANIONS_DIR`), one per
/// holder. A companion is just a process on a port, so without a record of which holder serves which
/// device the only way to stop one was `pkill -f "amoo companion"` — which stops every companion on
/// the machine, other sessions' included.
struct CompanionRegistry: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["AMOO_COMPANIONS_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Amoo/companions", directoryHint: .isDirectory)
        }
    }

    private func fileURL(platform: String, port: Int) -> URL {
        directory.appending(path: "\(platform)-\(port).json")
    }

    func register(_ registration: CompanionRegistration) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(registration) else { return }
        try? data.write(to: fileURL(platform: registration.platform, port: registration.port), options: .atomic)
    }

    /// Removes the record, but only when `pid` still owns it, so a late exit of an old holder cannot
    /// delete its replacement's record.
    func unregister(platform: String, port: Int, pid: Int32) {
        let url = fileURL(platform: platform, port: port)
        guard let current = read(url), current.pid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Live registrations, sorted by port. Records whose holder is gone are deleted as they are found.
    func entries(isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) -> [CompanionRegistration] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        var live: [CompanionRegistration] = []
        for url in urls where url.pathExtension == "json" {
            guard let registration = read(url) else { continue }
            if isAlive(registration.pid) {
                live.append(registration)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return live.sorted { ($0.port, $0.platform) < ($1.port, $1.platform) }
    }

    private func read(_ url: URL) -> CompanionRegistration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CompanionRegistration.self, from: data)
    }
}
