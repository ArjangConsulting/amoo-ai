import AmooCore
import Foundation
import SwiftyShell

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    case emptyCommand
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)
    case unsupportedPlatform
    case unsupportedPipeline
    /// A device command (such as `adb … am force-stop`) did not answer in time: the device or its
    /// tool server stopped responding, which is not what the calling step was about.
    case deviceUnresponsive(operation: String, seconds: Int)
    /// adb (or simctl) no longer sees the device: an emulator that exited or was killed, or a
    /// disconnected phone. `output` is the tool's own message, for example
    /// `adb: device 'emulator-5554' not found`.
    case deviceDisconnected(command: String, output: String)

    /// The tool message that means the device is gone, rather than that the command failed on it.
    static func isDisconnectedDeviceOutput(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("no devices/emulators found")
            || (text.contains("device '") && text.contains("' not found"))
            || text.contains("error: device offline")
            || text.contains("invalid device state: shutdown")
    }

    /// A failed command, classified as a vanished device when its output says so.
    static func failed(command: String, exitCode: Int32, output: String) -> Self {
        isDisconnectedDeviceOutput(output)
            ? .deviceDisconnected(command: command, output: output)
            : .nonZeroExit(command: command, exitCode: exitCode, stderr: output)
    }

    /// Whether the device, not the step, is the problem; tool replies show these in prose.
    public var isDeviceFailure: Bool {
        switch self {
        case .deviceUnresponsive, .deviceDisconnected: true
        default: false
        }
    }
}

extension ProcessRunnerError: LocalizedError {
    /// Without this, `.localizedDescription` bridges to Foundation's generic NSError text
    /// ("The operation couldn't be completed. (ProcessRunner.ProcessRunnerError error 0.)"),
    /// discarding the command/exit code/stderr already captured in `nonZeroExit`.
    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            "No command was provided to run."
        case let .nonZeroExit(command, exitCode, stderr):
            "Command failed (exit \(exitCode)): \(command)"
                + (stderr.isEmpty ? "" : "\n\(stderr)")
        case .unsupportedPlatform:
            "This operation is not supported on the current platform."
        case .unsupportedPipeline:
            "This process runner does not support command pipelines."
        case let .deviceUnresponsive(operation, seconds):
            "The device did not respond: \(operation) did not finish within \(seconds)s. The simulator or"
                + " emulator (or its simctl/adb) is unresponsive, not the app. Recover the runtime with"
                + " `amoo env up --platform <p> --runtime-id <id>`; cold-boot an emulator whose adb stays unresponsive."
        case let .deviceDisconnected(command, output):
            "The device is gone: \(output.trimmingCharacters(in: .whitespacesAndNewlines)) (while running"
                + " \(command)). The emulator or simulator exited or was disconnected; this is not an app failure."
                + " Check `adb devices` or `xcrun simctl list devices booted`, then start it again with"
                + " `amoo env up --platform <p> --device <id>` (or `--avd <name>`) and rerun the step."
        }
    }
}

/// Complete execution request, preserving environment, working directory, timeout, and output policy.
public struct ProcessExecutionRequest: Sendable {
    public let command: Command
    public let context: ShellContext

    public init(command: Command, context: ShellContext) {
        self.command = command
        self.context = context
    }
}

public protocol ProcessRunner: Sendable {
    func run(_ arguments: [String]) async throws -> ProcessResult
    func run(_ request: ProcessExecutionRequest) async throws -> ProcessResult
    func run(_ pipeline: Pipeline, context: ShellContext) async throws -> ProcessResult
}

public extension ProcessRunner {
    /// Compatibility adapter for argv-only test doubles. New doubles should capture the request.
    func run(_ request: ProcessExecutionRequest) async throws -> ProcessResult {
        let command = request.command
        return try await run([command.executableOverride ?? command.executableName] + command.arguments)
    }

    func run(_: Pipeline, context _: ShellContext) async throws -> ProcessResult {
        throw ProcessRunnerError.unsupportedPipeline
    }
}

public struct SystemProcessRunner: ProcessRunner {
    private let context: ShellContext

    public init(context: ShellContext = .init()) {
        self.context = context
    }

    public func run(_ arguments: [String]) async throws -> ProcessResult {
        guard !arguments.isEmpty else {
            throw ProcessRunnerError.emptyCommand
        }

        let command = try bounded(Command(arguments[0]).args(Array(arguments.dropFirst())), context: context)
        return try await ProcessTracing.trace(executable: arguments[0], arguments: Array(arguments.dropFirst())) {
            do {
                return try await command.run(in: context).processResult
            } catch let error as ShellError {
                if case let .exitFailure(_, output) = error {
                    return output.processResult
                }
                throw error
            }
        }
    }

    public func run(_ request: ProcessExecutionRequest) async throws -> ProcessResult {
        let command = try bounded(request.command, context: request.context)
        return try await ProcessTracing.trace(
            executable: request.command.executableOverride ?? request.command.executableName,
            arguments: request.command.arguments
        ) {
            try await SubprocessExecutor().execute(command, in: request.context).processResult
        }
    }

    public func run(_ pipeline: Pipeline, context: ShellContext) async throws -> ProcessResult {
        guard OperationDeadline.current != nil, pipeline.stages.count >= 2 else {
            return try await SubprocessExecutor().execute(pipeline, in: context).processResult
        }
        let stages = try pipeline.stages.map { try bounded($0, context: context) }
        let limited = stages.dropFirst(2).reduce(stages[0].pipe(to: stages[1])) { $0.pipe(to: $1) }
        return try await SubprocessExecutor().execute(limited, in: context).processResult
    }

    private func bounded(_ command: Command, context: ShellContext) throws -> Command {
        try Task.checkCancellation()
        guard let deadline = OperationDeadline.current else { return command }
        guard ContinuousClock.now < deadline else { throw OperationDeadline.DeadlineExceeded() }
        let existing = command.timeoutOverride ?? context.defaultTimeout ?? .seconds(86400)
        return command.timeout(OperationDeadline.remaining(cappedAt: existing))
    }
}

public struct ProcessRunnerCommandExecutor: CommandExecutor {
    private let processRunner: any ProcessRunner

    public init(processRunner: any ProcessRunner) {
        self.processRunner = processRunner
    }

    public func execute(_ command: Command, in context: ShellContext) async throws -> ShellOutput {
        let result = try await processRunner.run(ProcessExecutionRequest(command: command, context: context))
        return ShellOutput(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    public func execute(_ pipeline: Pipeline, in context: ShellContext) async throws -> ShellOutput {
        let result = try await processRunner.run(pipeline, context: context)
        return ShellOutput(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    /// Delegates independent launches to the system executor, or records them through a test runner.
    public func spawnDetached(_ command: Command, in context: ShellContext) async throws -> Int32 {
        if processRunner is SystemProcessRunner {
            return try await SubprocessExecutor().spawnDetached(command, in: context)
        }
        _ = try await processRunner.run(ProcessExecutionRequest(command: command, context: context))
        return 1
    }

    public func spawn(
        _ command: Command,
        in context: ShellContext,
        teardown: TeardownStrategy
    ) async throws -> any SpawnedProcess {
        if processRunner is SystemProcessRunner {
            return try await SubprocessExecutor().spawn(command, in: context, teardown: teardown)
        }

        let result = try await processRunner.run(ProcessExecutionRequest(command: command, context: context))
        return MockSpawnedProcess(
            processIdentifier: 1,
            output: ShellOutput(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        )
    }
}

public extension ShellOutput {
    var processResult: ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
