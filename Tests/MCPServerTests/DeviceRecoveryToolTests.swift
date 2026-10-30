import AmooCore
@testable import MCPServer
import XCTest

final class DeviceRecoveryToolTests: XCTestCase {
    func testKnownIdentityAvoidsAnUnresponsiveLookupBeforeWakeAndFailureDiagnostics() async {
        let driver = RecoveryToolDriver(state: .on, blockIdentity: true)
        let executor = DriverToolExecutor(driver: driver, defaultPlatform: .android, defaultDeviceID: "emulator-5556")
        let started = ContinuousClock.now
        let wake = await executor.execute(toolName: "device_wake", arguments: [:])
        let query = await executor.execute(toolName: "find_elements", arguments: [:])
        XCTAssertFalse(wake.isError, wake.content)
        XCTAssertTrue(query.isError)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        let identityReads = await driver.identityReads
        XCTAssertEqual(identityReads, 0)
    }

    func testShutdownNamesTheDeviceItActedOn() async {
        let result = await DriverToolExecutor(driver: RecoveryToolDriver(state: .on))
            .execute(toolName: "device_shutdown", arguments: [:])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("android device mock"), result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["device_id"]?.stringValue, "mock")
    }

    func testUnlockRequestedForASecureLockFailsAsCredentialRequired() async {
        let result = await DriverToolExecutor(driver: RecoveryToolDriver(state: .locked, unlockResult: .locked))
            .execute(toolName: "device_wake", arguments: ["unlock": "true"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("credential_required") || result.content.contains("never enters"))
        XCTAssertTrue(result.content.contains("PIN"), result.content)
    }

    func testUnlockRequestedForASwipeLockReportsTheDisplayOn() async {
        let result = await DriverToolExecutor(driver: RecoveryToolDriver(state: .locked, unlockResult: .on))
            .execute(toolName: "device_wake", arguments: ["unlock": "true"])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["screen_state"]?.stringValue, "on")
    }

    func testWakeWithoutUnlockNeverDismissesTheKeyguard() async {
        let driver = RecoveryToolDriver(state: .locked, unlockResult: .on)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "device_wake", arguments: [:])
        XCTAssertEqual(result.structuredContent?.objectValue?["screen_state"]?.stringValue, "locked")
        let dismissals = await driver.dismissals
        XCTAssertEqual(dismissals, 0)
    }

    func testWakeReportsLockedWithoutClaimingUnlocked() async {
        let result = await DriverToolExecutor(driver: RecoveryToolDriver(state: .locked))
            .execute(toolName: "device_wake", arguments: [:])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["screen_state"]?.stringValue, "locked")
        XCTAssertTrue(result.content.contains("Unlock"))
    }

    func testWakeRejectsAnUnverifiedOffState() async {
        let result = await DriverToolExecutor(driver: RecoveryToolDriver(state: .off))
            .execute(toolName: "device_wake", arguments: [:])
        XCTAssertTrue(result.isError)
    }

    func testObservationTimeoutIncludesIndependentGuestExecutionEvidence() async {
        let result = await DriverToolExecutor(driver: RecoveryToolDriver(state: .on))
            .execute(toolName: "find_elements", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["device_health"]?.stringValue, "responded")
        XCTAssertEqual(result.structuredContent?.objectValue?["device_execution_health"]?.stringValue, "timed_out")
        XCTAssertEqual(result.structuredContent?.objectValue?["failure_scope"]?.stringValue, "device_execution")
    }

    func testAVDTimeoutDoesNotSuggestSlowerAccessibilitySnapshots() async {
        let result = await DriverToolExecutor(driver: RecoveryToolDriver(state: .on))
            .execute(toolName: "set_display_preset", arguments: ["preset": "tablet"])
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.content.contains("accessibility snapshot"), result.content)
    }
}

private actor RecoveryToolDriver: PlatformDriver {
    let state: ScreenPowerState
    let blockIdentity: Bool
    let unlockResult: ScreenPowerState
    private(set) var identityReads = 0
    private(set) var dismissals = 0

    init(state: ScreenPowerState, blockIdentity: Bool = false, unlockResult: ScreenPowerState = .on) {
        self.state = state
        self.blockIdentity = blockIdentity
        self.unlockResult = unlockResult
    }

    func dismissKeyguard() async throws -> ScreenPowerState {
        dismissals += 1
        return unlockResult
    }

    func deviceInfo() async throws -> DeviceInfo {
        identityReads += 1
        if blockIdentity {
            try await Task.sleep(for: .seconds(30))
        }
        return DeviceInfo(id: "mock", name: "Mock", platform: .android, osVersion: "test", state: .booted)
    }

    func wake() async throws -> ScreenPowerState {
        state
    }

    func shutdown() async throws {}

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        throw AmooError.commandFailed(
            command: "find_elements",
            output: "deadlineExceeded: RPC timed out before completing"
        )
    }

    func setDisplayPreset(_: DisplayPreset) async throws -> DeviceDisplayConfiguration {
        throw AmooError.timeout(operation: "emu avd path", duration: Duration(milliseconds: 100))
    }

    func connectivityHealth() async -> ConnectivityHealth {
        ConnectivityHealth(
            deviceTransport: .init(status: "responded", source: "adb get-state"),
            companionRPC: .init(status: "responded", source: "capabilities"),
            deviceExecution: .init(status: "timed_out", source: "Android shell echo")
        )
    }
}
