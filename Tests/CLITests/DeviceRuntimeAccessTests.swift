import AmooCore
@testable import CLI
import Foundation
import MobileDevices
import XCTest

final class DeviceRuntimeAccessTests: XCTestCase {
    func testStoppingByDeviceRefusesLiveRuntimeWithoutCredentialOrForce() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let runtime = try store.start(platform: .ios, deviceID: "SIM")
        let refused = await runEnvDown(EnvDownOptions(deviceID: runtime.deviceID), store: store)
        XCTAssertEqual(refused.exitCode, 3, refused.output)
        XCTAssertNotNil(store.runtime(id: runtime.id))
        let forced = await runEnvDown(EnvDownOptions(deviceID: runtime.deviceID, force: true), store: store)
        XCTAssertEqual(forced.exitCode, 0, forced.output)
        XCTAssertNil(store.runtime(id: runtime.id))
    }

    func testForceRemovesRecordWhenAndroidStopFails() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let runtime = try store.start(platform: .android, deviceID: "emulator-test")
        let forced = await runEnvDown(
            EnvDownOptions(deviceID: runtime.deviceID, force: true),
            store: store,
            dependencies: EnvDownDependencies(stopAndroid: { _ in false })
        )
        XCTAssertEqual(forced.exitCode, 0, forced.output)
        XCTAssertNil(store.runtime(id: runtime.id, includingExpired: true))
    }

    func testStartExplainsAnExpiredRuntimeThatCouldNotBeCleanedUp() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url, ttl: 60, reaper: { _ in false })
        let runtime = try store.start(platform: .ios, deviceID: "SIM", now: Date().addingTimeInterval(-120))
        XCTAssertThrowsError(try store.start(platform: .ios, deviceID: "SIM")) {
            let message = "\($0)"
            XCTAssertTrue(message.contains(runtime.id), message)
            XCTAssertTrue(message.contains("env down"), message)
        }
    }

    func testOwnersSkipTheAccessLockButFreeDevicesTakeIt() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let runtime = try store.start(platform: .ios, deviceID: "SIM")
        let first = try acquireRuntimeDeviceAccess(deviceID: "SIM", runtimeID: runtime.id, store: store)
        let second = try acquireRuntimeDeviceAccess(deviceID: "SIM", runtimeID: runtime.id, store: store)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertThrowsError(try acquireRuntimeDeviceAccess(deviceID: "SIM", runtimeID: nil, store: store))

        let held = try acquireRuntimeDeviceAccess(deviceID: "FREE", runtimeID: nil, store: store)
        XCTAssertNotNil(held)
        XCTAssertThrowsError(try acquireRuntimeDeviceAccess(deviceID: "FREE", runtimeID: nil, store: store))
    }

    func testRuntimeDirectoryOverrideIsolatesTheLegacyLeaseDirectory() throws {
        let directory = try makeScratchDirectory().url.path
        let isolated = DeviceRuntimeStore(ttl: 60, environment: ["AMOO_RUNTIME_DIR": directory])
        XCTAssertNil(isolated.legacyDirectory)
        let shared = DeviceRuntimeStore(
            ttl: 60,
            environment: ["AMOO_RUNTIME_DIR": directory, "AMOO_LEASE_DIR": directory + "-leases"]
        )
        XCTAssertNotNil(shared.legacyDirectory)
    }

    func testEnvUpSummaryShowsTheRuntimeCredential() {
        var report = EnvUpReport(ok: true, platform: "ios")
        report.runtimeID = "runtime-1a2b3c4d"
        report.device = EnvDeviceReport(id: "SIM", name: "iPhone", bootedByEnv: false)
        report.port = 22093
        XCTAssertTrue(report.humanSummary.contains("--runtime-id runtime-1a2b3c4d"))
        XCTAssertTrue(report.humanSummary.contains("AMOO_RUNTIME_ID=runtime-1a2b3c4d"))
    }

    func testExportedRuntimeIDDoesNotTriggerEnvUpReuse() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let options = EnvUpOptions(platform: .android)
        let reused = await reuseDeviceRuntime(options, store: store, dependencies: EnvUpDependencies())
        XCTAssertNil(reused)
    }
}
