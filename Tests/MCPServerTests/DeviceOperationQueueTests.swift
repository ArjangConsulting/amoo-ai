import AmooCore
import Foundation
@testable import MCPServer
import TestSession
import XCTest

final class DeviceOperationQueueTests: XCTestCase {
    func testCancelInterruptsActiveWorkAndLeavesOtherDevicesUsable() async {
        let queue = DeviceOperationQueue()
        let started = expectation(description: "operation started")
        let running = Task {
            await queue.run(key: "android:phone") {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(60))
                    return .success("unexpected completion")
                } catch {
                    return .error("cancelled")
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await queue.cancel(key: "android:phone")
        let result = await running.value
        XCTAssertTrue(result.isError)
        let other = await queue.run(key: "android:emulator") { .success("ok") }
        XCTAssertFalse(other.isError)
    }
}

private actor StalledDriver: PlatformDriver {
    let started: XCTestExpectation
    private(set) var terminations = 0

    init(started: XCTestExpectation) {
        self.started = started
    }

    func pressHome() async throws {
        started.fulfill()
        try await Task.sleep(for: .seconds(60))
    }

    func terminateApp(appID _: String) async throws {
        terminations += 1
    }
}

private struct RecoveryBootstrapper: SessionBootstrapper {
    let driver: StalledDriver

    func bootstrap(_: SessionBootstrapRequest) async throws -> BootstrapResult {
        BootstrapResult(driver: driver, deviceID: "phone", platform: .android, cleanup: {})
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        []
    }

    func companionStatus(platform _: Platform, deviceHint _: String?) async throws -> String {
        "ready"
    }
}

extension DeviceOperationQueueTests {
    func testStatusAndForcedCloseBypassStalledDeviceWork() async throws {
        let started = expectation(description: "device action started")
        let driver = StalledDriver(started: started)
        let manager = SessionManager(bootstrapper: RecoveryBootstrapper(driver: driver))
        let session = try await manager.startSession(appID: "app", platform: .android)
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let action = Task { await executor.execute(toolName: "press_home", arguments: ["session_id": session.id]) }
        defer { action.cancel() }
        await fulfillment(of: [started], timeout: 2)
        let recovered = expectation(description: "control plane remains responsive")
        let recovery = Task {
            let status = await executor.execute(toolName: "companion_status", arguments: ["platform": "android"])
            XCTAssertFalse(status.isError)
            let result = await executor.execute(
                toolName: "end_session", arguments: ["session_id": session.id, "force": "true"]
            )
            XCTAssertFalse(result.isError)
            recovered.fulfill()
        }
        defer { recovery.cancel() }
        await fulfillment(of: [recovered], timeout: 2)
        let active = await session.isActive
        let terminations = await driver.terminations
        XCTAssertFalse(active)
        XCTAssertEqual(terminations, 0)
        let cancelled = await action.value
        XCTAssertTrue(cancelled.isError)
    }
}
