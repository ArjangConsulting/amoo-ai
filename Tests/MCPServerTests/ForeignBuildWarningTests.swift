import AmooCore
import Foundation
@testable import MCPServer
import ProcessRunner
import TestCommons
import XCTest

private struct StubRunner: ProcessRunner {
    var stdout: String
    var exitCode: Int32 = 0
    func run(_: [String]) async throws -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: stdout, stderr: "")
    }
}

final class ForeignBuildWarningTests: XCTestCase {
    private var scratch: TemporaryDirectory?

    /// `device_install_app` rejects a missing path before installing, so stage a real bundle.
    private func appBundlePath() throws -> String {
        let scratch = try TemporaryDirectory()
        self.scratch = scratch
        let app = scratch.url.appending(path: "App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app.path
    }

    override func tearDown() {
        try? scratch?.remove()
        super.tearDown()
    }

    private func detector(reporting foreign: Bool) -> ForeignBuildDetector {
        let runner = foreign
            ? StubRunner(stdout: "4242 /usr/bin/xcodebuild build\n", exitCode: 0)
            : StubRunner(stdout: "", exitCode: 1)
        return ForeignBuildDetector(processRunner: runner, ownProcessIDs: [])
    }

    func testDeviceInstallAppSurfacesContentionWarning() async throws {
        let path = try appBundlePath()
        let executor = DriverToolExecutor(driver: MockDriver(), foreignBuildDetector: detector(reporting: true))
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "device_install_app", arguments: ["path": path])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("App installed from \(path)"))
        XCTAssertTrue(result.content.contains(ForeignBuildDetector.contentionWarning))
        guard case let .object(fields)? = result.structuredContent,
              case let .array(warnings)? = fields["warnings"],
              case let .string(first)? = warnings.first
        else {
            return XCTFail("expected structured warnings array")
        }
        XCTAssertEqual(first, ForeignBuildDetector.contentionWarning)
    }

    func testDeviceInstallAppQuietWhenNoForeignBuild() async throws {
        let path = try appBundlePath()
        let executor = DriverToolExecutor(driver: MockDriver(), foreignBuildDetector: detector(reporting: false))
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "device_install_app", arguments: ["path": path])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "App installed from \(path)")
        XCTAssertNil(result.structuredContent)
    }

    func testDeviceInstallAppRejectsMissingPathBeforeInstalling() async {
        let driver = MockDriver()
        let server = MCPServer(executor: DriverToolExecutor(driver: driver))
        let missing = NSTemporaryDirectory() + "amoo-missing-\(UUID().uuidString)/App.app"

        let result = await server.execute(toolName: "device_install_app", arguments: ["path": missing])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("No app artifact at"), result.content)
        let calls = await driver.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("install:") })
    }

    func testExecutorDefaultsToDisabledDetector() async throws {
        let path = try appBundlePath()
        // A bare executor must not shell out to pgrep from unit tests.
        let executor = DriverToolExecutor(driver: MockDriver())
        let server = MCPServer(executor: executor)
        let result = await server.execute(toolName: "device_install_app", arguments: ["path": path])
        XCTAssertEqual(result.content, "App installed from \(path)")
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
