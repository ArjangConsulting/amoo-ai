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
}
