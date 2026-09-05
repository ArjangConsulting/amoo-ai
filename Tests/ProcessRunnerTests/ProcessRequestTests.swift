import Foundation
import ProcessRunner
import SwiftyShell
import XCTest

final class ProcessRequestTests: XCTestCase {
    func testAdapterPreservesCommandExecutionPolicy() async throws {
        let runner = RequestCapturingRunner()
        let executor = ProcessRunnerCommandExecutor(processRunner: runner)
        let command = Command("tool", arguments: "argument with spaces")
            .env("FIXTURE", "sample")
            .workingDirectory("/tmp")
            .timeout(7)
            .outputLimit(1234)
        _ = try await executor.execute(command, in: ShellContext())
        let captured = await runner.captured()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.command.arguments, ["argument with spaces"])
        XCTAssertEqual(request.command.environmentOverrides["FIXTURE"], "sample")
        XCTAssertEqual(request.command.workingDirectoryOverride, "/tmp")
        XCTAssertEqual(request.command.timeoutOverride, 7)
        XCTAssertEqual(request.command.outputLimitOverride, 1234)
    }

    func testPipelineConnectsOutputToNextStage() async throws {
        let executor = ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner())
        let pipeline = Command("printf", arguments: "%s", "hello")
            .pipe(to: Command("tr", arguments: "a-z", "A-Z"))
        let result = try await executor.execute(pipeline, in: ShellContext())
        XCTAssertEqual(result.stdout, "HELLO")
        XCTAssertEqual(result.exitCode, 0)
    }
}

private actor RequestCapturingRunner: ProcessRunner {
    private var request: ProcessExecutionRequest?

    func run(_: [String]) async throws -> ProcessResult {
        XCTFail("The complete request must be used")
        return ProcessResult(exitCode: 1, stdout: "", stderr: "")
    }

    func run(_ request: ProcessExecutionRequest) async throws -> ProcessResult {
        self.request = request
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func captured() -> ProcessExecutionRequest? {
        request
    }
}
