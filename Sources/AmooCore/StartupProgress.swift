import Foundation

/// Build policy for session startup. Reuse never invokes a build tool.
public enum SessionBuildMode: String, Sendable {
    case auto, reuse, rebuild
}

/// Request-scoped progress, inherited by structured child tasks.
public enum StartupProgress {
    @TaskLocal public static var reporter: (@Sendable (String) async -> Void)?
    @TaskLocal public static var startup: StartupOperation?

    public static func report(_ message: String) async {
        await startup?.update(message)
        await reporter?(message)
    }
}

/// Tracks concurrent startup stages and elapsed time without blocking status polling.
public actor StartupOperation {
    public let id: String
    private let started = ContinuousClock.now
    private var messages: [String] = []
    private var state = "starting"
    private var finished: ContinuousClock.Instant?

    public init(id: String = UUID().uuidString) {
        self.id = id
    }

    public func update(_ message: String) {
        messages.append(message)
        if messages.count > 30 {
            messages.removeFirst()
        }
    }

    public func finish(success: Bool) {
        state = success ? "ready" : "failed"
        finished = .now
    }

    public func summary() -> String {
        let elapsed = Int(started.duration(to: finished ?? .now).components.seconds)
        return "Startup \(id): \(state), \(elapsed)s elapsed\n" + messages.joined(separator: "\n")
    }
}

/// Recent startups, available to clients that do not surface MCP progress notifications.
public actor StartupProgressStore {
    public static let shared = StartupProgressStore()
    private var operations: [StartupOperation] = []

    public func add(_ operation: StartupOperation) {
        operations.append(operation)
        if operations.count > 20 {
            operations.removeFirst()
        }
    }

    public func summaries() async -> String {
        var result: [String] = []
        for operation in operations {
            await result.append(operation.summary())
        }
        return result.isEmpty ? "No session startups recorded." : result.joined(separator: "\n\n")
    }
}
