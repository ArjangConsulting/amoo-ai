import AmooCore
import Foundation
@testable import MCPServer
import ProcessRunner
import XCTest

private struct StubRunner: ProcessRunner {
    var stdout: String
    var exitCode: Int32 = 0
    func run(_: [String]) async throws -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: stdout, stderr: "")
    }
}

final class ForeignBuildWarningTests: XCTestCase {
    private func detector(reporting foreign: Bool) -> ForeignBuildDetector {
        let runner = foreign
            ? StubRunner(stdout: "4242 /usr/bin/xcodebuild build\n", exitCode: 0)
            : StubRunner(stdout: "", exitCode: 1)
        return ForeignBuildDetector(processRunner: runner, ownProcessIDs: [])
    }

    func testDeviceInstallAppSurfacesContentionWarning() async {
        let executor = DriverToolExecutor(driver: MockDriver(), foreignBuildDetector: detector(reporting: true))
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "device_install_app", arguments: ["path": "/tmp/App.app"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("App installed from /tmp/App.app"))
        XCTAssertTrue(result.content.contains(ForeignBuildDetector.contentionWarning))
        guard case let .object(fields)? = result.structuredContent,
              case let .array(warnings)? = fields["warnings"],
              case let .string(first)? = warnings.first
        else {
            return XCTFail("expected structured warnings array")
        }
        XCTAssertEqual(first, ForeignBuildDetector.contentionWarning)
    }

    func testDeviceInstallAppQuietWhenNoForeignBuild() async {
        let executor = DriverToolExecutor(driver: MockDriver(), foreignBuildDetector: detector(reporting: false))
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "device_install_app", arguments: ["path": "/tmp/App.app"])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "App installed from /tmp/App.app")
        XCTAssertNil(result.structuredContent)
    }

    func testExecutorDefaultsToDisabledDetector() async {
        // A bare executor must not shell out to pgrep from unit tests.
        let executor = DriverToolExecutor(driver: MockDriver())
        let server = MCPServer(executor: executor)
        let result = await server.execute(toolName: "device_install_app", arguments: ["path": "/tmp/App.app"])
        XCTAssertEqual(result.content, "App installed from /tmp/App.app")
    }

    /// Regression: another test runner hijacking the leased device surfaced only as an opaque
    /// "RPC timed out before completing".
    func testTimeoutOnAHijackedDeviceNamesTheOtherRunner() async {
        let runner = StubRunner(
            stdout: "9001 /usr/bin/xcodebuild test -destination id=mock -scheme Other\n",
            exitCode: 0
        )
        let executor = DriverToolExecutor(
            driver: MockDriver(),
            foreignBuildDetector: ForeignBuildDetector(processRunner: runner, ownProcessIDs: [])
        )
        let message = await executor.failureMessage(
            toolName: "tap",
            error: AmooError.commandFailed(command: "tap", output: "deadlineExceeded: RPC timed out before completing"),
            arguments: [:]
        )
        XCTAssertTrue(message.contains("device hijacked"), message)
        XCTAssertTrue(message.contains("xcodebuild test -destination id=mock"), message)
        XCTAssertTrue(message.contains("Leases only coordinate amoo users"), message)
    }

    func testTimeoutWithoutAHijackerKeepsTheOriginalError() async {
        let executor = DriverToolExecutor(driver: MockDriver(), foreignBuildDetector: detector(reporting: false))
        let message = await executor.failureMessage(
            toolName: "tap",
            error: AmooError.commandFailed(command: "tap", output: "RPC timed out before completing"),
            arguments: [:]
        )
        XCTAssertTrue(message.hasPrefix("tap failed:"), message)
        XCTAssertFalse(message.contains("hijacked"), message)
    }
}
