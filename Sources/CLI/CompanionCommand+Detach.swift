import AmooCore
import Foundation
import ProcessRunner
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - `amoo companion start --detach`

/// The `companion start` command line a detached process runs: this invocation minus `--detach`, with
/// the port and ready timeout made explicit so the parent polls exactly what the child listens on.
func detachedCompanionStartArguments(
    options: CompanionCommandOptions,
    executable: String,
    port: Int,
    readyTimeoutSeconds: Int
) -> [String] {
    var arguments = [
        executable, "companion", "start",
        "--platform", options.platform.rawValue,
        "--device", options.deviceID,
        "--port", String(port),
        "--ready-timeout", String(readyTimeoutSeconds)
    ]
    if let appID = options.appID {
        arguments += ["--app", appID]
    }
    if let companionDir = options.companionDir {
        arguments += ["--companion-dir", companionDir]
    }
    if options.force {
        arguments.append("--force")
    }
    return arguments
}

/// How `--detach` reaches the outside world, so a test can drive every outcome without a device.
struct DetachedCompanionHooks: Sendable {
    var executablePath: @Sendable () -> String?
    /// Starts the process in its own session and returns its pid.
    var spawn: @Sendable (_ arguments: [String], _ logPath: String) async throws -> Int32
    var isReady: @Sendable (_ port: Int) async -> Bool
    var isAlive: @Sendable (_ pid: Int32) -> Bool
    /// Stops a process that never became ready.
    var stop: @Sendable (_ pid: Int32) -> Void
    var pollInterval: Swift.Duration
    /// Extra time allowed on top of the ready timeout for a cold build.
    var buildSlackSeconds: Int

    static let live = Self(
        executablePath: { AmooBuildInfo.current.executablePath },
        spawn: { arguments, logPath in
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return try await DetachedProcess.spawn(arguments, logPath: logPath)
        },
        isReady: { await isCompanionReady(host: "127.0.0.1", port: $0) },
        isAlive: { kill($0, 0) == 0 },
        stop: { stopProcess(pid: $0) },
        pollInterval: .seconds(2),
        buildSlackSeconds: 600
    )
}

/// Starts the companion in a background process and returns once it answers, leaving it running.
///
/// The foreground `start` owns the runner and tears it down on Ctrl-C, so a script or agent that
/// wanted a companion left behind had to background it with `&` and poll for readiness itself.
/// This does that with the same detached-process mechanism `amoo env up` uses: the process is this
/// command re-run without `--detach`, in its own session, so it outlives this process and still
/// restarts a runner that dies. `kill <pid>` shuts it down cleanly.
func runDetachedCompanionStart(
    options: CompanionCommandOptions,
    hooks: DetachedCompanionHooks = .live
) async -> CLIResult {
    let platform = options.platform
    let port = options.port ?? (platform == .ios ? CompanionConfig.defaultPort : AndroidCompanionConfig.defaultPort)
    let readyTimeout = options.readyTimeoutSeconds ?? (platform == .ios
        ? CompanionConfig.readyTimeoutFromEnvironment()
        : AndroidCompanionConfig.readyTimeoutFromEnvironment())
    guard let executable = hooks.executablePath() else {
        return CLIResult(output: "Cannot locate the amoo executable to start the companion.", exitCode: 1)
    }
    let log = NSTemporaryDirectory() + "amoo-companion-\(platform.rawValue)-\(port).log"
    let arguments = detachedCompanionStartArguments(
        options: options, executable: executable, port: port, readyTimeoutSeconds: readyTimeout
    )

    let pid: Int32
    do {
        pid = try await hooks.spawn(arguments, log)
    } catch {
        return CLIResult(output: "Companion start failed: \(error)", exitCode: 1)
    }

    // The process builds (iOS: minutes on a cold cache) and then waits `readyTimeout` itself.
    let deadline = ContinuousClock.now.advanced(by: .seconds(readyTimeout + hooks.buildSlackSeconds))
    while ContinuousClock.now < deadline {
        if await hooks.isReady(port) {
            return CLIResult(
                output: "Companion ready on port \(port) (pid \(pid)), running in the background.\n"
                    + "Log: \(log)\nStop it with: kill \(pid)",
                exitCode: 0
            )
        }
        guard hooks.isAlive(pid) else {
            return CLIResult(
                output: "The companion process exited before becoming ready:\n" + logTail(log),
                exitCode: 1
            )
        }
        try? await Task.sleep(for: hooks.pollInterval)
    }
    hooks.stop(pid)
    return CLIResult(
        output: "The companion did not become ready on port \(port):\n" + logTail(log),
        exitCode: 1
    )
}
