import Foundation

/// Where a `companion warm` run is in its lifecycle. `warm` writes the record as it progresses so
/// a concurrent `companion status` (fired by an agent that backgrounded `warm` as step 0) can
/// report progress instead of the caller blocking a later tool call on the cold-start wait.
enum CompanionPhase: String, Codable, Sendable {
    case building
    case built
    case launching
    case ready
    case failed
    case notStarted = "not_started"

    /// Exit code for `amoo companion status`: 0 = usable now, 2 = in progress, 1 = needs action.
    var exitCode: Int32 {
        switch self {
        case .ready, .built: 0
        case .building, .launching: 2
        case .failed, .notStarted: 1
        }
    }
}

struct CompanionStatusRecord: Codable, Sendable {
    var phase: CompanionPhase
    var platform: String
    var deviceID: String
    var port: Int
    var updatedAt: Date
    var detail: String?
}

/// A single JSON file under the companion build dir, last-writer-wins. Not a queue or a lock —
/// just enough shared state for `status` to answer "is warming still going / did it fail".
struct CompanionStatusStore: Sendable {
    let fileURL: URL

    init(companionDir: String) {
        fileURL = URL(fileURLWithPath: companionDir)
            .appendingPathComponent("build/.amoo-companion-status.json")
    }

    func write(_ record: CompanionStatusRecord) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func read() -> CompanionStatusRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CompanionStatusRecord.self, from: data)
    }
}

/// Convenience constructor stamping `updatedAt` with now.
func warmRecord(
    _ phase: CompanionPhase,
    platform: String,
    device: String,
    port: Int,
    detail: String?
) -> CompanionStatusRecord {
    CompanionStatusRecord(
        phase: phase,
        platform: platform,
        deviceID: device,
        port: port,
        updatedAt: Date(),
        detail: detail
    )
}
