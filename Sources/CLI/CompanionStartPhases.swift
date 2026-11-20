import AmooLogging
import Foundation
import Synchronization

private let logger = AmooLogger.forType(CompanionStartPhases.self)

/// One step of a companion start, as `env up` reports it.
struct CompanionStartPhase: Codable, Equatable {
    /// `check`, `build`, `simulator`, `install.app`, `install.test`, `prepare`, `launch` or `runner`.
    var name: String
    /// What the step did: `built`, `cached`, `prebuilt`, `installed`, `reused`, `launched`…
    var outcome: String
    var milliseconds: Int

    enum CodingKeys: String, CodingKey {
        case name, outcome
        case milliseconds = "ms"
    }
}

/// Records the phases of one `amoo companion start` for the `env up` that spawned it.
///
/// `env up` runs the companion as a detached process and only watches its port, so on its own it
/// cannot tell a warm start (cached build, APKs already on the device) from a rebuild. The child
/// writes each phase to the file named by `AMOO_COMPANION_PHASES_PATH`; the parent reads it once
/// the port answers. Without that variable nothing is written.
final class CompanionStartPhases: Sendable {
    static let environmentKey = "AMOO_COMPANION_PHASES_PATH"
    static let shared = CompanionStartPhases(path: ProcessInfo.processInfo.environment[environmentKey])

    private let path: String?
    private let phases = Mutex<[CompanionStartPhase]>([])

    /// Where `recordIdentity` writes, next to the phases; nil when nothing is recorded.
    var identityPath: String? {
        path.map { Self.identityPath(phasesPath: $0) }
    }

    init(path: String?) {
        self.path = path.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Records `name` as having taken the time since `start`.
    func record(_ name: String, outcome: String, since start: ContinuousClock.Instant) {
        let elapsed = milliseconds(since: start)
        let snapshot = phases.withLock { phases in
            phases.append(CompanionStartPhase(name: name, outcome: outcome, milliseconds: elapsed))
            return phases
        }
        logger.debug("Companion start phase", context: "phase=\(name) outcome=\(outcome) ms=\(elapsed)")
        guard let path else { return }
        do {
            try JSONEncoder().encode(snapshot).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            logger.error("Could not write companion start phases", error: error, context: "phase=\(name)")
        }
    }

    /// The phases a companion start wrote to `path`, or `nil` when it wrote none.
    static func read(path: String) -> [CompanionStartPhase]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode([CompanionStartPhase].self, from: data)
    }
}
