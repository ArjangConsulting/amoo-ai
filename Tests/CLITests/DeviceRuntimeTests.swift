import AmooCore
@testable import CLI
import Foundation
import MobileDevices
import XCTest

extension DeviceRuntimeStore {
    /// An empty store under the temp directory, so tests never see a developer's real runtimes.
    /// The reaper is a no-op unless given: the real one force-stops companions on live emulators.
    static func temporary(
        ttl: TimeInterval = DeviceRuntimeStore.defaultTTL,
        reaper: @escaping @Sendable (DeviceRuntime) -> Void = { _ in }
    ) -> DeviceRuntimeStore {
        DeviceRuntimeStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("amoo-runtimes-\(UUID().uuidString)"),
            ttl: ttl,
            reaper: { runtime in reaper(runtime); return true }
        )
    }
}

final class DeviceRuntimeTests: XCTestCase {
    func testAcquireIsExclusiveAndOwnerHasAccess() throws {
        let store = DeviceRuntimeStore.temporary()
        let runtime = try store.start(platform: .android, deviceID: "emulator-5554", deviceName: "Medium", owner: "a")

        XCTAssertThrowsError(try store.start(
            platform: .android,
            deviceID: "emulator-5554",
            deviceName: nil,
            owner: "b"
        )) {
            guard case let .controlledByOther(process) = $0 as? DeviceAccessError else { return XCTFail("\($0)") }
            XCTAssertEqual(process.id, runtime.id)
        }
        guard case let .owned(owned) = store.access(deviceID: "emulator-5554", presenting: runtime.id) else {
            return XCTFail("owner should have access")
        }
        XCTAssertEqual(owned.id, runtime.id)
        guard case let .claimedByOther(process) = store.access(deviceID: "emulator-5554", presenting: nil) else {
            return XCTFail("others should be refused")
        }
        XCTAssertEqual(process.id, runtime.id)
        XCTAssertEqual(store.access(deviceID: "emulator-5556", presenting: nil), .free)
    }

    /// Regression: sessions drove each other's simulators; a controlled device must be refused.
    func testEnforceRefusesOtherSessionsAndRenewsTheOwner() throws {
        let store = DeviceRuntimeStore.temporary()
        let runtime = try store.start(platform: .ios, deviceID: "SIM-1", deviceName: nil, owner: nil)

        XCTAssertThrowsError(try enforceDeviceAccess(deviceID: "SIM-1", runtime: "runtime-other", store: store))
        XCTAssertNoThrow(try enforceDeviceAccess(deviceID: "SIM-1", runtime: runtime.id, store: store))
        XCTAssertNoThrow(try enforceDeviceAccess(deviceID: "SIM-2", runtime: nil, store: store))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.runtime(id: runtime.id)).expiresAt, runtime.expiresAt)
    }

    func testExpiredRuntimesFreeTheDevice() throws {
        let store = DeviceRuntimeStore.temporary(ttl: 60)
        let past = Date().addingTimeInterval(-3600)
        _ = try store.start(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil, now: past)
        XCTAssertEqual(store.access(deviceID: "emulator-5554", presenting: nil), .free)
        XCTAssertNoThrow(try store.start(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil))
    }

    /// Regression: an expired runtime's file was deleted but its companion process kept running.
    func testExpiredRuntimeIsReapedBeforeItsFileIsRemoved() throws {
        let reaped = ReapRecorder()
        let store = DeviceRuntimeStore.temporary(ttl: 60) { reaped.record($0.id) }
        let past = Date().addingTimeInterval(-3600)
        let runtime = try store.start(
            platform: .android,
            deviceID: "emulator-5554",
            deviceName: nil,
            owner: nil,
            now: past
        )

        XCTAssertEqual(store.reapExpired().map(\.id), [runtime.id])
        XCTAssertEqual(reaped.ids, [runtime.id])
        XCTAssertTrue(store.reapExpired().isEmpty)
        XCTAssertEqual(reaped.ids, [runtime.id], "the file is gone, so it is reaped only once")
    }

    /// Regression: `env list`, `doctor` and access checks reaped expired runtimes as a side effect.
    func testReadingAnExpiredRuntimeNeitherReapsNorRemovesIt() throws {
        let reaped = ReapRecorder()
        let store = DeviceRuntimeStore.temporary(ttl: 60) { reaped.record($0.id) }
        let past = Date().addingTimeInterval(-3600)
        let runtime = try store.start(
            platform: .android,
            deviceID: "emulator-5554",
            deviceName: nil,
            owner: nil,
            now: past
        )

        XCTAssertTrue(store.all().isEmpty)
        XCTAssertNil(store.runtime(forDevice: "emulator-5554"))
        XCTAssertNil(store.runtime(id: runtime.id))
        XCTAssertEqual(store.access(deviceID: "emulator-5554", presenting: nil), .free)
        XCTAssertTrue(reaped.ids.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(deviceID: "emulator-5554").path))
    }

    func testAcquiringADeviceReapsItsExpiredRuntime() throws {
        let reaped = ReapRecorder()
        let store = DeviceRuntimeStore.temporary(ttl: 60) { reaped.record($0.id) }
        let past = Date().addingTimeInterval(-3600)
        let expired = try store.start(
            platform: .android,
            deviceID: "emulator-5554",
            deviceName: nil,
            owner: nil,
            now: past
        )

        let fresh = try store.start(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil)
        XCTAssertEqual(reaped.ids, [expired.id])
        XCTAssertEqual(store.runtime(forDevice: "emulator-5554")?.id, fresh.id)
    }

    func testReapingSkipsADeviceAnotherSessionIsDriving() throws {
        let reaped = ReapRecorder()
        let store = DeviceRuntimeStore.temporary(ttl: 60) { reaped.record($0.id) }
        let past = Date().addingTimeInterval(-3600)
        _ = try store.start(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil, now: past)
        let claim = try DeviceAccessLock(deviceID: "emulator-5554", store: store)
        defer { claim.release() }

        XCTAssertTrue(store.reapExpired().isEmpty)
        XCTAssertTrue(reaped.ids.isEmpty)
    }

    func testOwnerCanReleaseItsExpiredRuntime() throws {
        let store = DeviceRuntimeStore.temporary(ttl: 60)
        let past = Date().addingTimeInterval(-3600)
        let runtime = try store.start(
            platform: .android,
            deviceID: "emulator-5554",
            deviceName: nil,
            owner: nil,
            now: past
        )
        store.stop(runtime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(deviceID: "emulator-5554").path))
    }

    func testProcessCommandMatchingGuardsAgainstPIDReuse() {
        let process = "/x/amoo companion start --platform android --device emulator-5554 --port 22093"
        XCTAssertTrue(isCompanionProcessCommand(process, deviceID: "emulator-5554"))
        XCTAssertFalse(isCompanionProcessCommand(process, deviceID: "emulator-5556"))
        XCTAssertFalse(isCompanionProcessCommand("/usr/bin/vim notes.txt", deviceID: "emulator-5554"))
    }

    func testProcessCommandMatchingAcceptsExecutablePathsWithSpaces() {
        let process = "/Users/Jane Doe/bin/amoo companion start --platform ios --device SIM --port 22093"
        XCTAssertTrue(isCompanionProcessCommand(process, deviceID: "SIM"))
        XCTAssertFalse(isCompanionProcessCommand(
            "/Users/Jane Doe/bin/other companion start --device SIM",
            deviceID: "SIM"
        ))
    }

    func testParsesOrphanedProcessesFromPS() {
        let ps = """
          101 /usr/sbin/cron
         4242 /x/amoo companion start --platform android --device emulator-5554 --port 22093
         4243 /x/amoo companion start --platform ios --device AAAA-BBBB --port 22094
         4244 /x/amoo mcp serve
        """
        XCTAssertEqual(parseCompanionProcessPIDs(ps, deviceID: "emulator-5554"), [4242])
        XCTAssertEqual(parseCompanionProcessPIDs(ps, deviceID: "AAAA-BBBB"), [4243])
    }

    func testReleaseOnlyRemovesTheSameRuntime() throws {
        let store = DeviceRuntimeStore.temporary()
        let runtime = try store.start(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: nil)
        var impostor = runtime
        impostor.id = "runtime-impostor"
        store.stop(impostor)
        XCTAssertNotNil(store.runtime(forDevice: "emulator-5554"))
        store.stop(runtime)
        XCTAssertNil(store.runtime(forDevice: "emulator-5554"))
    }

    func testPresentedRuntimePrefersTheFlag() {
        XCTAssertEqual(presentedRuntime(flag: "a", environment: ["AMOO_RUNTIME_ID": "b"]), "a")
        XCTAssertEqual(presentedRuntime(flag: nil, environment: ["AMOO_RUNTIME_ID": "b"]), "b")
        XCTAssertNil(presentedRuntime(flag: nil, environment: [:]))
    }

    func testAutoSelectionSkipsRuntimeAndPhysicalDevices() async throws {
        let store = DeviceRuntimeStore.temporary()
        _ = try store.start(platform: .android, deviceID: "emulator-5554", deviceName: nil, owner: "other")
        let runner = MockCLIProcessRunner(results: [.success(.init(
            exitCode: 0,
            stdout: "List of devices attached\nphone\tdevice\nemulator-5554\tdevice\nemulator-5556\tdevice\n",
            stderr: ""
        ))])
        let selected = try await PlatformDeviceSelector(processRunner: runner, interactive: false, runtimeStore: store)
            .selectDevice(platform: .android)
        XCTAssertEqual(selected.deviceID, "emulator-5556")
    }

    func testAutoSelectionRefusesWhenOnlyAPhoneIsLeft() async {
        let runner = MockCLIProcessRunner(results: [.success(.init(
            exitCode: 0, stdout: "List of devices attached\nphone\tdevice\n", stderr: ""
        ))])
        do {
            _ = try await PlatformDeviceSelector(processRunner: runner, interactive: false, runtimeStore: .temporary())
                .selectDevice(platform: .android)
            XCTFail("a lone phone must not be auto-selected")
        } catch {
            XCTAssertTrue("\(error)".contains("never auto-selects a physical device"), "\(error)")
        }
    }
}

final class DeviceRuntimeEndpointTests: XCTestCase {
    private func controlled(port: Int?) throws -> (DeviceRuntimeStore, DeviceRuntime) {
        let store = DeviceRuntimeStore.temporary()
        var runtime = try store.start(platform: .ios, deviceID: "UDID-1", deviceName: "iPad", owner: "t")
        runtime.port = port
        return try (store, store.refresh(runtime))
    }

    private func options(args: [String]) throws -> DeviceCommandOptions {
        guard case let .success(parsed) = parseDeviceCommandOptions(args: args) else {
            throw XCTSkip("options did not parse")
        }
        return parsed
    }

    func testRuntimeSuppliesPortAndDevice() throws {
        let (store, runtime) = try controlled(port: 22093)
        let parsed = try options(args: ["--platform", "ios", "--runtime-id", runtime.id, "current_app"])

        let adopted = try parsed.applyingRuntime(store: store, environment: [:]).get()

        XCTAssertEqual(adopted.port, 22093)
        XCTAssertEqual(adopted.deviceID, "UDID-1")
    }

    func testRuntimeComesFromEnvironment() throws {
        let (store, runtime) = try controlled(port: 22093)
        let parsed = try options(args: ["--platform", "ios", "current_app"])

        let adopted = try parsed.applyingRuntime(store: store, environment: ["AMOO_RUNTIME_ID": runtime.id]).get()

        XCTAssertEqual(adopted.port, 22093)
    }

    func testExplicitPortAndDeviceBeatTheRuntime() throws {
        let (store, runtime) = try controlled(port: 22093)
        let parsed = try options(args: [
            "--platform", "ios", "--port", "22100", "--device", "UDID-1", "--runtime-id", runtime.id, "current_app"
        ])

        let adopted = try parsed.applyingRuntime(store: store, environment: [:]).get()

        XCTAssertEqual(adopted.port, 22100)
    }

    func testUnknownRuntimeIsRefused() throws {
        let parsed = try options(args: ["--platform", "ios", "--runtime-id", "runtime-nope", "current_app"])

        guard case .failure(.unknownRuntime) = parsed.applyingRuntime(store: .temporary(), environment: [:]) else {
            return XCTFail("Unknown runtime credentials must fail before device control")
        }
    }

    func testRuntimeForAnotherPlatformIsRefused() throws {
        let (store, runtime) = try controlled(port: 22093)
        let parsed = try options(args: ["--platform", "android", "--runtime-id", runtime.id, "current_app"])

        guard case let .failure(error) = parsed.applyingRuntime(store: store, environment: [:]) else {
            return XCTFail("an iOS runtime must not drive an Android call")
        }
        XCTAssertTrue("\(error)".contains("Pass --platform ios"), "\(error)")
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
