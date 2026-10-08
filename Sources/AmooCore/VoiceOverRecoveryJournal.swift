import Foundation

/// Durable restoration marker. It contains state and progress counts, never captured speech.
public struct VoiceOverRecoveryJournal: Sendable {
    public struct Record: Codable, Sendable {
        public var originalEnabled: Bool
        public var appID: String
        public var completedMoves: Int
        public var startedAt: Date
    }

    public let url: URL
    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Record? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }

    public func save(_ record: Record) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
