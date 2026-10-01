import AmooCore
import SwiftyShell

/// Launches independently owned tools in a new session through SwiftyShell.
public enum DetachedProcess {
    /// Starts a process that may outlive the launcher, optionally appending both streams to a log.
    /// The returned PID is also its process-group identifier; the caller owns eventual shutdown.
    @discardableResult
    public static func spawn(
        _ arguments: [String],
        logPath: String? = nil,
        environment: [String: String] = [:],
        context: ShellContext = .init()
    ) async throws -> Int32 {
        guard let executable = arguments.first else {
            throw AmooError.commandFailed(command: "spawn", output: "Missing executable.")
        }
        let destination: OutputDestination = logPath.map { .file(path: $0, append: true) } ?? .discard
        return try await Command(executable, arguments: Array(arguments.dropFirst()))
            .env(environment)
            .stdout(destination)
            .stderr(destination)
            .spawnDetached(in: context)
    }
}
