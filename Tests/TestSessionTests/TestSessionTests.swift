import AmooCore
import Foundation
@testable import TestSession
import XCTest

final class TestSessionTests: XCTestCase {
    func testRecordAccumulatesActionsWhileActive() async {
        let session = TestSession(
            id: "s1",
            appID: "com.example",
            deviceID: "dev-1",
            platform: .ios,
            driver: NoopDriver(),
            cleanup: {}
        )

        let action = SessionAction(
            timestamp: Date(),
            toolName: "tap",
            arguments: ["x": "10", "y": "20"],
            result: "Tapped",
            isError: false
        )

        await session.record(action)
        await session.record(action)

        let recorded = await session.actions
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.first?.toolName, "tap")
    }

    func testCloseTerminatesAppAndCallsCleanup() async {
        let driver = RecordingDriver()
        let cleanupCount = ActorCounter()
        let session = TestSession(
            id: "s1",
            appID: "com.example",
            deviceID: "dev-1",
            platform: .android,
            driver: driver,
            cleanup: { await cleanupCount.increment() }
        )

        await session.close()
        await session.close() // second call is a no-op

        let terminations = await driver.terminations
        XCTAssertEqual(terminations, ["com.example"])
        let cleanup = await cleanupCount.value
        XCTAssertEqual(cleanup, 1)

        let isActive = await session.isActive
        XCTAssertFalse(isActive)
        let endedAt = await session.endedAt
        XCTAssertNotNil(endedAt)
    }

    func testRecordIgnoresActionsAfterClose() async {
        let session = TestSession(
            id: "s1",
            appID: "com.example",
            deviceID: "dev-1",
            platform: .ios,
            driver: NoopDriver(),
            cleanup: {}
        )

        await session.close()
        await session.record(SessionAction(
            timestamp: Date(),
            toolName: "tap",
            arguments: [:],
            result: "Tapped",
            isError: false
        ))

        let recorded = await session.actions
        XCTAssertTrue(recorded.isEmpty)
    }

    func testSessionManagerStartRegistersSession() async throws {
        let bootstrapper = MockBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper, idGenerator: { "fixed-id" })

        let session = try await manager.startSession(
            appID: "com.example",
            platform: .ios
        )

        XCTAssertEqual(session.id, "fixed-id")
        XCTAssertEqual(session.appID, "com.example")
        XCTAssertEqual(session.deviceID, "mock-device")

        let fetched = await manager.session("fixed-id")
        XCTAssertNotNil(fetched)
        let all = await manager.allSessions()
        XCTAssertEqual(all.count, 1)
    }

    func testSessionManagerEndClosesButPreservesSessionForReports() async throws {
        let bootstrapper = MockBootstrapper()
        let cleanupCount = ActorCounter()
        bootstrapper.cleanupHook = { await cleanupCount.increment() }
        let manager = SessionManager(bootstrapper: bootstrapper, idGenerator: { "s-end" })

        _ = try await manager.startSession(appID: "com.example", platform: .ios)
        try await manager.endSession("s-end")

        // Ended sessions remain queryable so get_session_report and
        // list_sessions can still surface their action history.
        let fetched = await manager.session("s-end")
        XCTAssertNotNil(fetched)
        let isActive = await fetched?.isActive
        XCTAssertEqual(isActive, false)
        let endedAt = await fetched?.endedAt
        XCTAssertNotNil(endedAt)
        let cleanup = await cleanupCount.value
        XCTAssertEqual(cleanup, 1)
    }

    func testSessionManagerEndCanRunTwice() async throws {
        let bootstrapper = MockBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper, idGenerator: { "s-twice" })

        _ = try await manager.startSession(appID: "com.example", platform: .ios)
        try await manager.endSession("s-twice")
        // Second end on the same session should not throw notFound — the
        // session is still registered, just inactive.
        try await manager.endSession("s-twice")
    }

    func testSessionManagerEndUnknownThrows() async {
        let manager = SessionManager(bootstrapper: MockBootstrapper())

        do {
            try await manager.endSession("does-not-exist")
            XCTFail("Expected SessionError.notFound")
        } catch let error as SessionError {
            XCTAssertEqual(error, .notFound("does-not-exist"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCloseAllClosesEveryActiveSession() async throws {
        let bootstrapper = MockBootstrapper()
        let cleanupCount = ActorCounter()
        bootstrapper.cleanupHook = { await cleanupCount.increment() }

        let idVendor = IDVendor(values: ["a", "b", "c"])
        let manager = SessionManager(
            bootstrapper: bootstrapper,
            idGenerator: { idVendor.next() }
        )

        _ = try await manager.startSession(appID: "com.a", platform: .ios)
        _ = try await manager.startSession(appID: "com.b", platform: .android)
        _ = try await manager.startSession(appID: "com.c", platform: .ios)

        await manager.closeAll()

        let remaining = await manager.allSessions()
        XCTAssertTrue(remaining.isEmpty)
        let cleanup = await cleanupCount.value
        XCTAssertEqual(cleanup, 3)
    }

    func testSessionReportSerializesAccumulatedActions() async throws {
        let session = TestSession(
            id: "report-1",
            appID: "com.example",
            deviceID: "dev",
            platform: .ios,
            driver: NoopDriver(),
            cleanup: {}
        )
        await session.record(SessionAction(
            timestamp: Date(),
            toolName: "tap",
            arguments: ["x": "1"],
            result: "Tapped",
            isError: false
        ))
        await session.record(SessionAction(
            timestamp: Date(),
            toolName: "tap_element",
            arguments: ["id": "btn"],
            result: "failure",
            isError: true
        ))

        let report = await SessionReport.make(from: session)
        XCTAssertEqual(report.sessionID, "report-1")
        XCTAssertEqual(report.actionCount, 2)
        XCTAssertEqual(report.errorCount, 1)
        XCTAssertEqual(report.platform, "ios")
        XCTAssertTrue(report.isActive)

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(SessionReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    func testListAvailableDevicesPassesThroughToBootstrapper() async throws {
        let bootstrapper = MockBootstrapper()
        bootstrapper.devices = [
            DeviceInfo(id: "dev-1", name: "iPhone 15", platform: .ios, osVersion: "17.0", state: .booted),
            DeviceInfo(id: "dev-2", name: "Pixel 7", platform: .android, osVersion: "14", state: .booted)
        ]
        let manager = SessionManager(bootstrapper: bootstrapper)

        let result = try await manager.listAvailableDevices(platform: nil)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.id, "dev-1")
    }
}

// MARK: - Test doubles

private actor ActorCounter {
    private(set) var value: Int = 0
    func increment() {
        value += 1
    }
}

private final class IDVendor: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        if values.isEmpty {
            return "extra"
        }
        return values.removeFirst()
    }
}

private final class MockBootstrapper: SessionBootstrapper, @unchecked Sendable {
    var devices: [DeviceInfo] = []
    var cleanupHook: @Sendable () async -> Void = {}
    var launchArguments: [String] = []
    var launchEnvironment: [String: String] = [:]

    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
        launchArguments = request.arguments
        launchEnvironment = request.environment
        let hook = cleanupHook
        return BootstrapResult(
            driver: NoopDriver(),
            deviceID: "mock-device",
            platform: request.platform,
            cleanup: { await hook() }
        )
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        devices
    }
}

private actor RecordingDriver: PlatformDriver {
    var terminations: [String] = []

    func boot() async throws {}
    func shutdown() async throws {}
    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "rec", name: "Recording", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path _: String) async throws {}
    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {}
    func terminateApp(appID: String) async throws {
        terminations.append(appID)
    }

    func uninstallApp(appID _: String) async throws {}
    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .notRunning
    }
}

private struct NoopDriver: PlatformDriver, Sendable {}
