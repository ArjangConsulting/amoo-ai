import Foundation

/// Persists a session's recorded history to disk so `get_session_report`,
/// `list_sessions`, and `compile_session_to_plan` still resolve a session after
/// the MCP server process restarts — the in-memory registry does not survive one.
///
/// Every method is best-effort: a persistence failure must never break a live
/// session, so writes swallow their errors and reads return `nil`.
public protocol SessionStore: Sendable {
    /// Directory that holds one session's artifacts (`report.json`, and — written
    /// by the MCP layer — `plan.json` / `flow.json`).
    func directory(for sessionID: String) -> URL

    /// Write (or overwrite) `report.json` for this session.
    func save(_ report: SessionReport) async

    /// Load a single session's `report.json`, or `nil` if none is on disk.
    func loadReport(sessionID: String) async -> SessionReport?

    /// Load every persisted session report under the store root.
    func loadAllReports() async -> [SessionReport]
}

/// File-backed `SessionStore`. Layout: `<root>/<session_id>/report.json`.
///
/// The root defaults to `~/Library/Application Support/Amoo/sessions` — the same
/// `Application Support/Amoo` tree the Studio layer already writes artifacts into,
/// and one that survives a reboot (unlike `$TMPDIR`). Override with the
/// `AMOO_SESSIONS_DIR` environment variable.
public struct FileSessionStore: SessionStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Resolves the root from `AMOO_SESSIONS_DIR`, falling back to
    /// `~/Library/Application Support/Amoo/sessions`.
    public init() {
        if let override = ProcessInfo.processInfo.environment["AMOO_SESSIONS_DIR"],
           !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Amoo/sessions", directoryHint: .isDirectory)
        }
    }

    public func directory(for sessionID: String) -> URL {
        root.appending(path: sessionID, directoryHint: .isDirectory)
    }

    public func save(_ report: SessionReport) async {
        let directory = directory(for: report.sessionID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(report)
            try data.write(to: directory.appending(path: "report.json"), options: .atomic)
        } catch {
            // Best-effort: a live session must not fail because its history could
            // not be flushed to disk.
        }
    }

    public func loadReport(sessionID: String) async -> SessionReport? {
        let url = directory(for: sessionID).appending(path: "report.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(SessionReport.self, from: data)
    }

    public func loadAllReports() async -> [SessionReport] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var reports: [SessionReport] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if let report = await loadReport(sessionID: entry.lastPathComponent) {
                reports.append(report)
            }
        }
        return reports
    }

    /// ISO-8601 *with* fractional seconds.
    ///
    /// `JSONEncoder.dateEncodingStrategy = .iso8601` uses `ISO8601DateFormatter`'s defaults, which
    /// omit fractional seconds — so every action timestamp was truncated to a whole second on the
    /// way to disk. That silently destroyed the only data the retry-collapse heuristic runs on: a
    /// live compile saw gaps of 2.461s and 2.449s, and the same session recompiled after a restart
    /// saw 2.0s and 2.0s. Sub-second gaps fared worse — 0.56s quantised to 0.0s or 1.0s depending
    /// on which side of a second boundary it fell — so the same recording could compile to a
    /// different plan depending on whether the session was still in memory.
    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the format style is a
    /// `Sendable` value type, so it can be shared from a `static let` under strict concurrency.
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// Reports written before the fix have no fractional part, so decoding accepts both forms.
    private static let plain = Date.ISO8601FormatStyle()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractional.format(date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? fractional.parse(raw) {
                return date
            }
            if let date = try? plain.parse(raw) {
                return date
            }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an ISO-8601 date, got '\(raw)'."
            ))
        }
        return decoder
    }()
}
