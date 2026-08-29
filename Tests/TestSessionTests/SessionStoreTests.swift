import AmooCore
import Foundation
@testable import TestSession
import XCTest

final class SessionStoreTests: XCTestCase {
    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "amoo-session-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func testFileStoreRoundTripsAReport() async {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSessionStore(root: root)

        let report = SessionReport(
            sessionID: "s-round",
            appID: "com.example",
            deviceID: "dev-1",
            platform: "ios",
            startedAt: Date(timeIntervalSince1970: 1000),
            endedAt: Date(timeIntervalSince1970: 1050),
            durationSeconds: 50,
            actionCount: 1,
            errorCount: 0,
            isActive: false,
            actions: [SessionAction(
                timestamp: Date(timeIntervalSince1970: 1010),
                toolName: "tap_element",
                arguments: ["id": "btn"],
                result: "ok",
                isError: false
            )]
        )

        await store.save(report)

        let loaded = await store.loadReport(sessionID: "s-round")
        XCTAssertEqual(loaded, report)

        let all = await store.loadAllReports()
        XCTAssertEqual(all.map(\.sessionID), ["s-round"])
    }

    func testLoadReportReturnsNilWhenAbsent() async {
        let store = FileSessionStore(root: makeTempRoot())
        let loaded = await store.loadReport(sessionID: "missing")
        XCTAssertNil(loaded)
        let all = await store.loadAllReports()
        XCTAssertTrue(all.isEmpty)
    }

    func testEnvOverrideWinsForDefaultInit() {
        let previous = ProcessInfo.processInfo.environment["AMOO_SESSIONS_DIR"]
        setenv("AMOO_SESSIONS_DIR", "/tmp/amoo-env-override", 1)
        defer {
            if let previous {
                setenv("AMOO_SESSIONS_DIR", previous, 1)
            } else {
                unsetenv("AMOO_SESSIONS_DIR")
            }
        }
        let store = FileSessionStore()
        XCTAssertEqual(store.root.path, "/tmp/amoo-env-override")
    }

    // MARK: - SessionManager persistence

    func testEndSessionPersistsReportToStore() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSessionStore(root: root)
        let manager = SessionManager(
            bootstrapper: StubBootstrapper(),
            idGenerator: { "s-persist" },
            store: store
        )

        _ = try await manager.startSession(appID: "com.example", platform: .ios)
        try await manager.endSession("s-persist")
        // Store writes are queued off the manager's actor; wait for them before reading back.
        await manager.drainPendingWrites()

        let onDisk = await store.loadReport(sessionID: "s-persist")
        XCTAssertEqual(onDisk?.sessionID, "s-persist")
        XCTAssertEqual(onDisk?.isActive, false)
    }

    func testReportResolvesFromDiskAfterProcessRestart() async throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSessionStore(root: root)

        // First "process": run and end a session.
        let first = SessionManager(
            bootstrapper: StubBootstrapper(),
            idGenerator: { "s-restart" },
            store: store
        )
        _ = try await first.startSession(appID: "com.example", platform: .android)
        try await first.endSession("s-restart")
        await first.drainPendingWrites()

        // Second "process": fresh manager, empty in-memory registry.
        let second = SessionManager(bootstrapper: StubBootstrapper(), store: store)
        let liveLookup = await second.session("s-restart")
        XCTAssertNil(liveLookup)

        let report = await second.report(for: "s-restart")
        XCTAssertEqual(report?.sessionID, "s-restart")
        XCTAssertEqual(report?.platform, "android")

        let all = await second.allReports()
        XCTAssertEqual(all.map(\.sessionID), ["s-restart"])
    }

    func testNoStoreMeansNoPersistenceAndNoDirectory() async throws {
        let manager = SessionManager(bootstrapper: StubBootstrapper(), idGenerator: { "s-nostore" })
        _ = try await manager.startSession(appID: "com.example", platform: .ios)
        try await manager.endSession("s-nostore")

        let directory = await manager.sessionDirectory(for: "s-nostore")
        XCTAssertNil(directory)
        // Live session is still queryable in-memory.
        let report = await manager.report(for: "s-nostore")
        XCTAssertEqual(report?.sessionID, "s-nostore")
    }
}

private final class StubBootstrapper: SessionBootstrapper, @unchecked Sendable {
    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
        BootstrapResult(
            driver: StubDriver(),
            deviceID: "stub-device",
            platform: request.platform,
            cleanup: {}
        )
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        []
    }
}

private struct StubDriver: PlatformDriver, Sendable {}
