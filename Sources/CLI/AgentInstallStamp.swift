import AmooCore
import AmooLogging
import Foundation

/// Committable provenance for installed AI client files, relative to the installation scope.
struct AgentInstallStamp: Codable {
    var schema = 1
    var amooVersion: String = AmooVersion.current
    var binary: String
    var clients: [String] = []
    var agents: [String] = []
    var files: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case schema, binary, clients, agents, files
        case amooVersion = "amoo_version"
    }

    static func url(in root: URL) -> URL {
        root.appendingPathComponent(".amoo-install.json")
    }

    static func read(in root: URL) throws -> Self? {
        let url = url(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard stamp.schema == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return stamp
    }

    static func relativePath(_ file: URL, root: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    mutating func merge(_ options: AgentInstallOptions, hashes: [String: String]) throws {
        amooVersion = AmooVersion.current
        binary = options.executablePath
        clients = Set(clients + options.clients.map(\.rawValue)).sorted()
        agents = Set(agents + options.agents).sorted()
        files.merge(hashes) { _, new in new }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: options.root, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(in: options.root), options: .atomic)
    }
}

/// Applies a caller's overwrite policy through the same atomic installer for install and update.
func writeAgentFiles(
    _ files: [AgentInstallFile],
    options: AgentInstallOptions,
    shouldWrite: (AgentInstallFile, Data?) -> Bool,
    skippedAction: (AgentInstallFile) -> String
) throws -> AgentInstallReport {
    let logger = AmooLogger.forType(AgentInstallStamp.self)
    logger.info("Installing AI client files", context: "root=\(options.root.path) files=\(files.count)")
    do {
        var stamp = try AgentInstallStamp.read(in: options.root) ?? AgentInstallStamp(binary: options.executablePath)
        var hashes: [String: String] = [:]
        var report = AgentInstallReport(ok: true, files: [])
        for file in files {
            let existing = try readAgentFile(file.destination)
            let action: String
            if existing == file.contents {
                action = "unchanged"
            } else if !shouldWrite(file, existing) {
                report.files.append(.init(path: file.destination.path, action: skippedAction(file)))
                continue
            } else if options.dryRun {
                action = existing == nil ? "would install" : "would update"
            } else {
                try FileManager.default.createDirectory(
                    at: file.destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try file.contents.write(to: file.destination, options: .atomic)
                action = existing == nil ? "installed" : "updated"
            }
            hashes[AgentInstallStamp.relativePath(file.destination, root: options.root)] = sha256Hex(file.contents)
            report.files.append(.init(path: file.destination.path, action: action))
        }
        if !options.dryRun {
            try stamp.merge(options, hashes: hashes)
        }
        logger.info("Installed AI client files", context: "root=\(options.root.path) files=\(report.files.count)")
        return report
    } catch {
        logger.error("AI client install failed", error: error, context: "root=\(options.root.path)")
        throw error
    }
}

func readAgentFile(_ url: URL) throws -> Data? {
    do { return try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return nil }
}
