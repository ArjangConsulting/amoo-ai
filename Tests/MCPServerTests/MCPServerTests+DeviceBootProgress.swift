import AmooCore
@testable import MCPServer
import TestCommons
import XCTest

extension MCPServerTests {
    func testDeviceBootReportsStagesAndRetainsStatusWithoutSession() async {
        let progress = TestValueBox<[String]>([])
        let reporter: @Sendable (String) async -> Void = { message in
            progress.withValue { $0.append(message) }
        }
        let server = MCPServer(executor: DriverToolExecutor(driver: MockDriver()))

        let result = await StartupProgress.$reporter.withValue(reporter) {
            await server.execute(toolName: "device_boot", arguments: [:])
        }

        XCTAssertFalse(result.isError)
        XCTAssertEqual(progress.get(), [
            "Resolving device for boot", "Booting bound device", "Verifying device boot state", "Device boot verified"
        ])
        let status = await server.execute(toolName: "session_startup_status", arguments: [:])
        XCTAssertTrue(status.content.contains("Device boot verified"))
        XCTAssertTrue(status.content.contains("ready"))
    }

    func testFailedBootRetainsFailureStagesBeforeSessionExists() async {
        let stack = makeSessionStack()
        let progress = TestValueBox<[String]>([])
        let reporter: @Sendable (String) async -> Void = { message in
            progress.withValue { $0.append(message) }
        }
        let server = MCPServer(executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager))

        let result = await StartupProgress.$reporter.withValue(reporter) {
            await server.execute(toolName: "device_boot", arguments: ["device_hint": "shutdown-simulator"])
        }

        XCTAssertTrue(result.isError)
        XCTAssertEqual(progress.get(), [
            "Resolving device for boot", "Device boot failed; inspect device state before retrying"
        ])
        let status = await server.execute(toolName: "session_startup_status", arguments: [:])
        XCTAssertTrue(status.content.contains("Device boot failed; inspect device state before retrying"))
        XCTAssertTrue(status.content.contains("failed"))
    }
}
