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
}

public protocol ProcessRunner: Sendable {
    func run(_ arguments: [String]) async throws -> ProcessResult
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
}

public struct ProcessRunnerCommandExecutor: CommandExecutor {
    private let processRunner: any ProcessRunner

    public init(processRunner: any ProcessRunner) {
        self.processRunner = processRunner
    }

    public func execute(_ command: Command, in context: ShellContext) async throws -> ShellOutput {
        let executable = command.executableOverride ?? command.executableName
        let result = try await processRunner.run([executable] + command.arguments)
        return ShellOutput(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    public func execute(_ pipeline: Pipeline, in context: ShellContext) async throws -> ShellOutput {
        var output = ShellOutput(stdout: "", stderr: "", exitCode: 0)
        for command in pipeline.stages {
            output = try await execute(command, in: context)
        }
        return output
    }
}

public extension ShellOutput {
    var processResult: ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
