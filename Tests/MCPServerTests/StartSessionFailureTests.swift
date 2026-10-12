import AmooCore
import Foundation
@testable import MCPServer
import TestSession
import XCTest

/// A `start_session` that dies inside the bootstrapper must come back as a tool error and leave the
/// server answering, not take the connection down with it ("Connection closed" on every later call).
final class StartSessionFailureTests: XCTestCase {
    private struct FailingBootstrapper: SessionBootstrapper {
        func bootstrap(_: SessionBootstrapRequest) async throws -> BootstrapResult {
            throw AmooError.commandFailed(command: "xcodebuild", output: "build failed")
        }

        func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
            [DeviceInfo(id: "sim-1", name: "iPhone", platform: .ios, osVersion: "27.2", state: .booted)]
        }

        func companionStatus(platform _: Platform, deviceHint _: String?) async throws -> String {
            "not_started"
        }
    }

    func testFailedBootstrapIsAToolErrorAndTheServerKeepsAnswering() async {
        let manager = SessionManager(bootstrapper: FailingBootstrapper())
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        XCTAssertTrue(started.isError)
        XCTAssertTrue(started.content.contains("build failed"), started.content)

        // The same server still serves control-plane and device calls after the failure.
        let devices = await server.execute(toolName: "list_devices", arguments: [:])
        XCTAssertFalse(devices.isError, devices.content)
        XCTAssertTrue(devices.content.contains("sim-1"), devices.content)
        let status = await server.execute(toolName: "companion_status", arguments: ["platform": "ios"])
        XCTAssertFalse(status.isError, status.content)
        let sessions = await server.execute(toolName: "list_sessions", arguments: [:])
        XCTAssertFalse(sessions.isError, sessions.content)
    }

    func testARetryAfterAFailedBootstrapStartsCleanly() async {
        let stack = makeStack(failFirst: true)
        let server = MCPServer(
            executor: DriverToolExecutor(driver: MockDriver(), sessionManager: stack),
            sessionManager: stack
        )
        let first = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        XCTAssertTrue(first.isError)
        let second = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        XCTAssertFalse(second.isError, second.content)
        XCTAssertNotNil(second.structuredContent?.objectValue?["session_id"]?.stringValue)
    }

    private actor FlakyBootstrapper: SessionBootstrapper {
        private var failuresLeft: Int
        private let inner = MockSessionBootstrapper()

        init(failures: Int) {
            failuresLeft = failures
        }

        func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw AmooError.commandFailed(command: "xcodebuild", output: "transient")
            }
            return try await inner.bootstrap(request)
        }

        func listDevices(platform: Platform?) async throws -> [DeviceInfo] {
            try await inner.listDevices(platform: platform)
        }

        func companionStatus(platform: Platform, deviceHint: String?) async throws -> String {
            try await inner.companionStatus(platform: platform, deviceHint: deviceHint)
        }
    }

    private func makeStack(failFirst: Bool) -> SessionManager {
        SessionManager(bootstrapper: FlakyBootstrapper(failures: failFirst ? 1 : 0))
    }
}
