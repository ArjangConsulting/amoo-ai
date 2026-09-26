import AmooCore
@testable import CLI
import Foundation
import XCTest

extension DeviceLeaseStore {
    /// An empty store under the temp directory, so tests never see a developer's real leases.
    static func temporary(ttl: TimeInterval = DeviceLeaseStore.defaultTTL) -> DeviceLeaseStore {
        DeviceLeaseStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("amoo-leases-\(UUID().uuidString)"),
            ttl: ttl
        )
    }
}

final class DeviceLeaseTests: XCTestCase {
    func testAcquireIsExclusiveAndOwnerHasAccess() throws {
        let store = DeviceLeaseStore.temporary()
        let lease = try store.acquire(platform: .android, deviceID: "emulator-5554", deviceName: "Medium", owner: "a")

        XCTAssertThrowsError(try store.acquire(
            platform: .android,
            deviceID: "emulator-5554",
            deviceName: nil,
            owner: "b"
        )) {
            guard case let .leasedByOther(holder) = $0 as? DeviceLeaseError else { return XCTFail("\($0)") }
            XCTAssertEqual(holder.id, lease.id)
        }
        guard case let .owned(owned) = store.access(deviceID: "emulator-5554", lease: lease.id) else {
            return XCTFail("owner should have access")
        }
        XCTAssertEqual(owned.id, lease.id)
        guard case let .leasedByOther(holder) = store.access(deviceID: "emulator-5554", lease: nil) else {
            return XCTFail("others should be refused")
        }
        XCTAssertEqual(holder.id, lease.id)
        XCTAssertEqual(store.access(deviceID: "emulator-5556", lease: nil), .free)
    }

    /// Regression: sessions drove each other's simulators; a leased device must be refused.
    func testEnforceRefusesOtherSessionsAndRenewsTheOwner() throws {
        let store = DeviceLeaseStore.temporary()
        let lease = try store.acquire(platform: .ios, deviceID: "SIM-1", deviceName: nil, owner: nil)

        XCTAssertThrowsError(try enforceLease(deviceID: "SIM-1", lease: "lease-other", store: store))
        XCTAssertNoThrow(try enforceLease(deviceID: "SIM-1", lease: lease.id, store: store))
        XCTAssertNoThrow(try enforceLease(deviceID: "SIM-2", lease: nil, store: store))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.lease(id: lease.id)).expiresAt, lease.expiresAt)
    }

    func testExpiredLeasesFreeTheDevice() throws {
        let store = DeviceLeaseStore.temporary(ttl: 60)
        let past = Date().addingTimeInterval(-3600)
        _ = try store.acquire(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil, now: past)
        XCTAssertEqual(store.access(deviceID: "emulator-5554", lease: nil), .free)
        XCTAssertNoThrow(try store.acquire(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil))
    }

    func testReleaseOnlyRemovesTheSameLease() throws {
        let store = DeviceLeaseStore.temporary()
        let lease = try store.acquire(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil)
        var impostor = lease
        impostor.id = "lease-impostor"
        store.release(impostor)
        XCTAssertNotNil(store.lease(forDevice: "emulator-5554"))
        store.release(lease)
        XCTAssertNil(store.lease(forDevice: "emulator-5554"))
    }

    func testPresentedLeasePrefersTheFlag() {
        XCTAssertEqual(presentedLease(flag: "a", environment: ["AMOO_LEASE": "b"]), "a")
        XCTAssertEqual(presentedLease(flag: nil, environment: ["AMOO_LEASE": "b"]), "b")
        XCTAssertNil(presentedLease(flag: nil, environment: [:]))
    }

    func testAutoSelectionSkipsLeasedAndPhysicalDevices() async throws {
        let store = DeviceLeaseStore.temporary()
        _ = try store.acquire(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: "other")
        let runner = MockCLIProcessRunner(results: [.success(.init(
            exitCode: 0,
            stdout: "List of devices attached\nphone\tdevice\nemulator-5554\tdevice\nemulator-5556\tdevice\n",
            stderr: ""
        ))])
        let selected = try await PlatformDeviceSelector(processRunner: runner, interactive: false, leaseStore: store)
            .selectDevice(platform: .android)
        XCTAssertEqual(selected.deviceID, "emulator-5556")
    }

    func testAutoSelectionRefusesWhenOnlyAPhoneIsLeft() async {
        let runner = MockCLIProcessRunner(results: [.success(.init(
            exitCode: 0, stdout: "List of devices attached\nphone\tdevice\n", stderr: ""
        ))])
        do {
            _ = try await PlatformDeviceSelector(processRunner: runner, interactive: false, leaseStore: .temporary())
                .selectDevice(platform: .android)
            XCTFail("a lone phone must not be auto-selected")
        } catch {
            XCTAssertTrue("\(error)".contains("never auto-selects a physical device"), "\(error)")
        }
    }
}
