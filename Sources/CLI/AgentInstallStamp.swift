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

    static func exists(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: root).path)
    }

    /// Reads the record. The file is committed, so a merge conflict or a newer schema can make it
    /// unreadable; `discardUnreadable` (`--force`) then treats the install as unrecorded instead of failing.
    static func read(in root: URL, discardUnreadable: Bool = false) throws -> Self? {
        let url = url(in: root)
        guard exists(in: root) else { return nil }
        do {
            let stamp = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard stamp.schema == 1 else {
                throw AgentInstallStampError(path: url.path, reason: "unsupported schema \(stamp.schema)")
            }
            return stamp
        } catch {
            let wrapped = error as? AgentInstallStampError
                ?? AgentInstallStampError(path: url.path, reason: "\(error)")
            guard discardUnreadable else { throw wrapped }
            AmooLogger.forType(Self.self).info("Discarding unreadable install record", context: "path=\(url.path)")
            return nil
        }
    }

    /// The executable `status` and `update` render with. A different build of the same release keeps the
    /// recorded one, so running a debug build does not repoint a Homebrew install; an upgrade or a missing
    /// recorded binary uses the running one. `--binary` always wins.
    static func resolvedBinary(_ options: AgentInstallOptions, stamp: Self?) -> String {
        guard !options.binaryGiven, let stamp, stamp.amooVersion == AmooVersion.current,
              FileManager.default.isExecutableFile(atPath: stamp.binary) else { return options.executablePath }
        return stamp.binary
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

struct AgentInstallStampError: Error, CustomStringConvertible {
    var path: String
    var reason: String

    var description: String {
        "\(path) is unreadable (\(reason)). Delete it, or run `amoo agent update --force` to rewrite it."
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
        var stamp = try AgentInstallStamp.read(in: options.root, discardUnreadable: options.force)
            ?? AgentInstallStamp(binary: options.executablePath)
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
