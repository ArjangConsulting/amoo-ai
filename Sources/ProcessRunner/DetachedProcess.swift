import AmooCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Starts a process that must outlive amoo itself — an Android emulator, above all.
///
/// A plain `Process` child stays in amoo's process group and session. Harnesses that run
/// `amoo mcp serve` (or a CLI call) under a process-group wrapper signal the whole group when
/// they tear down, and a closing terminal SIGHUPs its session, so the emulator died with its
/// launcher: "Wait for emulator … to shutdown gracefully before kill", exit 139, after boot.
/// `POSIX_SPAWN_SETSID` puts the child in a new session and process group, which neither reaches.
public enum DetachedProcess {
    /// Spawns `arguments` (resolved through `PATH`) in its own session with stdin from
    /// `/dev/null` and stdout/stderr appended to `logPath` (or discarded). `environment` entries
    /// are layered over this process's environment. Returns the pid, which is also the child's
    /// process-group id, so `kill(-pid, …)` reaches everything it starts.
    @discardableResult
    public static func spawn(
        _ arguments: [String],
        logPath: String? = nil,
        environment: [String: String] = [:]
    ) throws -> Int32 {
        guard let executable = arguments.first else {
            throw AmooError.commandFailed(command: "spawn", output: "Missing executable.")
        }

        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        let output = logPath ?? "/dev/null"
        posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, output, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)

        let cArguments = arguments.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }

        let merged = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        let cEnvironment = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cEnvironment.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawnp(&pid, executable, &fileActions, &attributes, cArguments, cEnvironment)
        guard status == 0 else {
            throw AmooError.commandFailed(
                command: arguments.joined(separator: " "),
                output: String(cString: strerror(status))
            )
        }
        return pid
    }
}
