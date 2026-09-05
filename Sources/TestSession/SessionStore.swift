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
    func loadAllSummaries() async -> [SessionReport]

    func loadAllReports() async -> [SessionReport]

    /// Durability of the latest attempted write in this process.
    func recordingHealth(sessionID: String) async -> String
}

public extension SessionStore {
    func loadAllSummaries() async -> [SessionReport] {
        await loadAllReports().map(\.summary)
    }

    func recordingHealth(sessionID _: String) async -> String {
        "unknown"
    }
}

private actor PersistenceHealth {
    private var states: [String: String] = [:]
    func set(_ id: String, state: String) {
        states[id] = state
    }

    func get(_ id: String) -> String {
        states[id] ?? "unknown"
    }
}

/// File-backed `SessionStore`. Layout: `<root>/<session_id>/report.json`.
///
/// The root defaults to `~/Library/Application Support/Amoo/sessions` — the same
/// `Application Support/Amoo` tree the Studio layer already writes artifacts into,
/// and one that survives a reboot (unlike `$TMPDIR`). Override with the
/// `AMOO_SESSIONS_DIR` environment variable.
public struct FileSessionStore: SessionStore {
    public let root: URL
    private let health = PersistenceHealth()

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
        let component = Self.validSessionID(sessionID) ? sessionID : "invalid-session-id"
        return root.appending(path: component, directoryHint: .isDirectory)
    }

    public func save(_ report: SessionReport) async {
        guard Self.validSessionID(report.sessionID) else { return }
        let directory = directory(for: report.sessionID)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let data = try SessionReport.makeJSONEncoder().encode(report)
            let url = directory.appending(path: "report.json")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let summaryURL = directory.appending(path: "summary.json")
            try SessionReport.makeJSONEncoder().encode(report.summary).write(to: summaryURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summaryURL.path)
            await health.set(report.sessionID, state: "saved")
        } catch {
            await health.set(report.sessionID, state: "failed")
            // Do not echo file contents, paths, or raw OS errors into shared logs.
            FileHandle.standardError.write(Data("[amoo] session persistence failed; recording is not durable\n".utf8))
        }
    }

    public func loadReport(sessionID: String) async -> SessionReport? {
        guard Self.validSessionID(sessionID) else { return nil }
        let url = directory(for: sessionID).appending(path: "report.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SessionReport.makeJSONDecoder().decode(SessionReport.self, from: data)
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

    public func loadAllSummaries() async -> [SessionReport] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        var summaries: [SessionReport] = []
        for entry in entries where Self.validSessionID(entry.lastPathComponent) {
            let summaryURL = entry.appending(path: "summary.json")
            let reportURL = entry.appending(path: "report.json")
            let summaryDate = try? summaryURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let reportDate = try? reportURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let summaryDate, let reportDate, summaryDate >= reportDate,
               let data = try? Data(contentsOf: summaryURL),
               let summary = try? SessionReport.makeJSONDecoder().decode(SessionReport.self, from: data) {
                summaries.append(summary)
            } else if let report = await loadReport(sessionID: entry.lastPathComponent) {
                // Legacy stores and a crash between report and index replacement remain readable.
                summaries.append(report.summary)
            }
        }
        return summaries
    }

    public func recordingHealth(sessionID: String) async -> String {
        await health.get(sessionID)
    }

    private static func validSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200
            && id.unicodeScalars
            .allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }
    }
}
