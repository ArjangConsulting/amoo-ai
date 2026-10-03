import AmooCore
@testable import CLI
import Foundation
import XCTest

extension DeviceLeaseStore {
    /// An empty store under the temp directory, so tests never see a developer's real leases.
    /// The reaper is a no-op unless given: the real one force-stops companions on live emulators.
    static func temporary(
        ttl: TimeInterval = DeviceLeaseStore.defaultTTL,
        reaper: @escaping @Sendable (DeviceLease) -> Void = { _ in }
    ) -> DeviceLeaseStore {
        DeviceLeaseStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("amoo-leases-\(UUID().uuidString)"),
            ttl: ttl,
            reaper: reaper
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

    /// Regression: an expired lease's file was deleted but its companion holder kept running.
    func testExpiredLeaseIsReapedBeforeItsFileIsRemoved() throws {
        let reaped = ReapRecorder()
        let store = DeviceLeaseStore.temporary(ttl: 60) { reaped.record($0.id) }
        let past = Date().addingTimeInterval(-3600)
        let lease = try store.acquire(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil, now: past)

        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(reaped.ids, [lease.id])
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertEqual(reaped.ids, [lease.id], "the file is gone, so it is reaped only once")
    }

    func testHolderCommandMatchingGuardsAgainstPIDReuse() {
        let holder = "/x/amoo companion start --platform android --device emulator-5554 --port 22093 --ready-timeout 180"
        XCTAssertTrue(isCompanionHolderCommand(holder, deviceID: "emulator-5554"))
        XCTAssertFalse(isCompanionHolderCommand(holder, deviceID: "emulator-5556"))
        XCTAssertFalse(isCompanionHolderCommand("/usr/bin/vim notes.txt", deviceID: "emulator-5554"))
    }

    func testParsesOrphanedHoldersFromPS() {
        let ps = """
          101 /usr/sbin/cron
         4242 /x/amoo companion start --platform android --device emulator-5554 --port 22093
         4243 /x/amoo companion start --platform ios --device AAAA-BBBB --port 22094
         4244 /x/amoo mcp serve
        """
        XCTAssertEqual(parseCompanionHolderPIDs(ps, deviceID: "emulator-5554"), [4242])
        XCTAssertEqual(parseCompanionHolderPIDs(ps, deviceID: "AAAA-BBBB"), [4243])
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

private final class ReapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var ids: [String] {
        lock.withLock { recorded }
    }

    func record(_ id: String) {
        lock.withLock { recorded.append(id) }
    }
}
