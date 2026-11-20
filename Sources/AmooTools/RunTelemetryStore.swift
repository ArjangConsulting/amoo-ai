// swiftlint:disable multiline_arguments
import Foundation
import TestSession

struct RunCallIdentity: Sendable {
    let runID: String
    let callID: String
    @TaskLocal static var current: Self?
}

/// Run-wide cost accounting, including requests without a live session and unfinished attempts.
/// Each request owns one atomic file, allowing multiple CLI/MCP processes to share a run UUID.
public actor RunTelemetryStore {
    struct Entry: Codable, Sendable {
        let runID: String
        let callID: String
        let tool: String
        let startedAt: String
        var finishedAt: String?
        var sessionID: String?
        var status = "unfinished"
        var metrics: [String: Int] = [:]
        /// The failure's machine code (`session_not_found`, `startup_failed`), so a report can say why
        /// calls failed and not only how many. Absent on success and in entries older than the field.
        var errorCode: String?
    }

    struct Snapshot: Sendable {
        let totals: [String: Int]
        let sessions: [String]
        let health: String
    }

    private let directory: URL?
    private var entries: [String: Entry] = [:]
    private var writeFailures: Set<String> = []

    /// Omitting the directory keeps telemetry in memory, suitable for embedded clients and tests.
    public init(directory: URL? = nil) {
        self.directory = directory
    }

    /// Uses the session store's configured root and survives server restart or abandoned sessions.
    public static func persistent() -> RunTelemetryStore {
        RunTelemetryStore(directory: FileSessionStore().root.appending(path: "runs"))
    }

    func begin(runID: String, tool: String, sessionID: String?) -> RunCallIdentity {
        let call = RunCallIdentity(runID: runID, callID: UUID().uuidString)
        save(Entry(
            runID: runID, callID: call.callID, tool: tool,
            startedAt: Date().ISO8601Format(), sessionID: sessionID
        ))
        return call
    }

    func operation(_ call: RunCallIdentity, milliseconds: Int, recovery: Bool, evidenceBytes: Int, pixels: Int) {
        guard var entry = entries[call.callID] else { return }
        entry.metrics["operations", default: 0] += 1
        entry.metrics["evidence_image_bytes", default: 0] += evidenceBytes
        entry.metrics["evidence_image_pixels", default: 0] += pixels
        if recovery {
            entry.metrics["recovery_ms", default: 0] += milliseconds
        }
        save(entry)
    }

    func finish(
        _ call: RunCallIdentity, failed: Bool, errorCode: String? = nil, sessionID: String?, metrics: [String: Int]
    ) {
        guard var entry = entries[call.callID] else { return }
        entry.status = failed ? "failed" : "completed"
        entry.errorCode = failed ? errorCode : nil
        entry.finishedAt = Date().ISO8601Format()
        entry.sessionID = sessionID ?? entry.sessionID
        entry.metrics.merge(metrics, uniquingKeysWith: +)
        if entry.tool == "start_session" {
            entry.metrics["setup_ms"] = metrics["elapsed_ms"]
        }
        if ["reset_companion", "companion_warm"].contains(entry.tool) {
            entry.metrics["recovery_ms", default: 0] += metrics["elapsed_ms", default: 0]
        }
        save(entry)
        if directory != nil, !writeFailures.contains(call.runID) {
            entries.removeValue(forKey: call.callID)
        }
    }

    func snapshot(
        runID: String,
        excluding callID: String?
    ) -> Snapshot {
        let (all, readFailed) = loadEntries(runID: runID)
        var totals = Self.emptyTotals
        var sessions: Set<String> = []
        for entry in all.values where entry.callID != callID {
            totals["client_calls", default: 0] += 1
            if entry.status == "failed" {
                totals["failed_calls", default: 0] += 1
            }
            if entry.status == "unfinished" {
                totals["unfinished_calls", default: 0] += 1
            }
            if entry.tool == "start_session" {
                totals["startup_attempts", default: 0] += 1
                if entry.status == "failed" {
                    totals["failed_startups", default: 0] += 1
                }
            }
            if let session = entry.sessionID {
                sessions.insert(session)
            }
            for (key, value) in entry.metrics {
                totals[key, default: 0] += value
            }
        }
        let health = directory == nil ? "memory" : readFailed || writeFailures.contains(runID) ? "incomplete" : "saved"
        return Snapshot(totals: totals, sessions: sessions.sorted(), health: health)
    }

    private func loadEntries(runID: String) -> ([String: Entry], Bool) {
        var all = entries.filter { $0.value.runID == runID }
        var readFailed = false
        if let directory {
            let root = directory.appending(path: runID)
            if FileManager.default.fileExists(atPath: root.path) {
                do {
                    for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                        where file.pathExtension == "json" {
                        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: file))
                        if entry.runID == runID, all[entry.callID] == nil {
                            all[entry.callID] = entry
                        }
                    }
                } catch { readFailed = true }
            }
        }
        return (all, readFailed)
    }

    private static let emptyTotals = [
        "client_calls": 0, "failed_calls": 0, "unfinished_calls": 0,
        "startup_attempts": 0, "failed_startups": 0, "operations": 0,
        "text_payload_bytes": 0, "wire_response_bytes": 0, "image_bytes": 0, "image_pixels": 0,
        "evidence_image_bytes": 0, "evidence_image_pixels": 0, "setup_ms": 0, "recovery_ms": 0,
        "elapsed_ms": 0
    ]

    private func save(_ entry: Entry) {
        entries[entry.callID] = entry
        guard let directory, UUID(uuidString: entry.runID) != nil else { return }
        do {
            let root = directory.appending(path: entry.runID)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(entry)
            let file = root.appending(path: entry.callID + ".json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            writeFailures.insert(entry.runID)
        }
    }
}

// swiftlint:enable multiline_arguments
