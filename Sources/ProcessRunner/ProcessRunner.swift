import Foundation

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
    public init() {}

    public func run(_ arguments: [String]) async throws -> ProcessResult {
        guard !arguments.isEmpty else {
            throw ProcessRunnerError.emptyCommand
        }

        #if os(macOS) || os(Linux)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
        #else
        throw ProcessRunnerError.unsupportedPlatform
        #endif
    }
}
