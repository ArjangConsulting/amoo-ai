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

        let command = Command(arguments[0]).args(Array(arguments.dropFirst()))
        do {
            return try await command.run(in: context).processResult
        } catch let error as ShellError {
            if case let .exitFailure(_, output) = error {
                return output.processResult
            }
            throw error
        }
    }

    public func run(_ request: ProcessExecutionRequest) async throws -> ProcessResult {
        try await SubprocessExecutor().execute(request.command, in: request.context).processResult
    }

    public func run(_ pipeline: Pipeline, context: ShellContext) async throws -> ProcessResult {
        try await SubprocessExecutor().execute(pipeline, in: context).processResult
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
