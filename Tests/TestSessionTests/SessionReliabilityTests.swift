// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import TestCommons
@testable import TestSession
import XCTest

private struct ReliabilityBootstrapper: SessionBootstrapper {
    let cancelBeforeReturning: Bool
    let cleanup: @Sendable () async -> Void
    func bootstrap(_: SessionBootstrapRequest) async throws -> BootstrapResult {
        if cancelBeforeReturning {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return BootstrapResult(driver: ReliabilityNoopDriver(), deviceID: "phone", platform: .ios, cleanup: cleanup)
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        []
    }
}

private struct ReliabilityNoopDriver: PlatformDriver {}

private actor ReleaseCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor HeldSessionStore: SessionStore {
    let root: URL
    var hold = false
    var writing = false
    var saves = 0
    var releaseWrite: CheckedContinuation<Void, Never>?
    init(root: URL) {
        self.root = root
    }

    nonisolated func directory(for sessionID: String) -> URL {
        root.appending(path: sessionID)
    }

    func save(_: SessionReport) async {
        writing = true
        if hold {
            await withCheckedContinuation { releaseWrite = $0 }
        }
        saves += 1
        writing = false
    }

    func block() {
        hold = true
    }

    func release() {
        hold = false; releaseWrite?.resume(); releaseWrite = nil
    }

    func loadReport(sessionID _: String) async -> SessionReport? {
        nil
    }

    func loadAllReports() async -> [SessionReport] {
        []
    }

    func recordingHealth(sessionID _: String) async -> String {
        saves > 0 ? "saved" : "unknown"
    }
}

final class SessionReliabilityTests: XCTestCase {
    func testIdleSessionIsEndedAndReleasesItsDeviceWhileAnActiveOneStays() async throws {
        let released = ReleaseCounter()
        let manager = SessionManager(
            bootstrapper: ReliabilityBootstrapper(cancelBeforeReturning: false) { await released.increment() },
            idleLimit: .seconds(60)
        )
        let idle = try await manager.startSession(appID: "com.example", platform: .ios)
        let busy = try await manager.startSession(appID: "com.example", platform: .ios)

        let none = await manager.endIdleSessions(now: .now + .seconds(30))
        XCTAssertEqual(none, [])
        // Resolving a session is what a tool call does, so it restarts that session's clock.
        try await Task.sleep(for: .milliseconds(20))
        _ = await manager.session(busy.id)
        let ended = await manager.endIdleSessions(now: .now + .seconds(60) - .milliseconds(10))

        XCTAssertEqual(ended, [idle.id])
        let idleActive = await idle.isActive
        let busyActive = await busy.isActive
        XCTAssertFalse(idleActive)
        XCTAssertTrue(busyActive)
        let count = await released.value
        XCTAssertEqual(count, 1)
        let reason = await manager.wasEndedForInactivity(idle.id)
        XCTAssertTrue(reason)
    }

    func testIdleLimitComesFromTheEnvironmentAndZeroDisablesIt() {
        XCTAssertEqual(SessionManager.idleLimitFromEnvironment([:]), .seconds(1800))
        XCTAssertEqual(SessionManager.idleLimitFromEnvironment(["AMOO_SESSION_IDLE_MINUTES": "5"]), .seconds(300))
        XCTAssertNil(SessionManager.idleLimitFromEnvironment(["AMOO_SESSION_IDLE_MINUTES": "0"]))
    }

    func testCancelledBootstrapCleansUpWithoutPublishingSession() async {
        let cleaned = expectation(description: "bootstrap resources released")
        let manager = SessionManager(bootstrapper: ReliabilityBootstrapper(cancelBeforeReturning: true, cleanup: {
            cleaned.fulfill()
        }))
        let result = await Task {
            do {
                _ = try await manager.startSession(appID: "app", platform: .ios)
                return false
            } catch is CancellationError {
                return true
            } catch { return false }
        }.value
        XCTAssertTrue(result)
        await fulfillment(of: [cleaned], timeout: 1)
        let sessions = await manager.allSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testPendingDurabilityAndCoalescedWrites() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = HeldSessionStore(root: scratch.url)
        let manager = SessionManager(
            bootstrapper: ReliabilityBootstrapper(cancelBeforeReturning: false, cleanup: {}), store: store
        )
        let session = try await manager.startSession(appID: "app", platform: .ios)
        await manager.drainPendingWrites()
        await store.block()
        await manager.flush(session.id)
        _ = try await waitUntil(timeout: .seconds(1), pollInterval: .milliseconds(5), operation: {
            await store.writing
        }, matching: { $0 })
        for _ in 0 ..< 100 {
            await manager.flush(session.id)
        }
        let health = await manager.recordingHealth(for: session.id)
        XCTAssertEqual(health, "pending")
        await store.release()
        await manager.drainPendingWrites()
        let saved = await manager.recordingHealth(for: session.id)
        let count = await store.saves
        XCTAssertEqual(saved, "saved")
        XCTAssertEqual(count, 3, "initial, blocked, and one coalesced latest snapshot")
    }

    func testSummaryPreservesCountsWithoutActions() async {
        let session = TestSession(
            id: "test",
            appID: "app",
            deviceID: "phone",
            platform: .ios,
            driver: ReliabilityNoopDriver(),
            cleanup: {}
        )
        for index in 0 ..< 1000 {
            await session.record(SessionAction(
                timestamp: Date(),
                toolName: "tap",
                arguments: [:],
                result: "ok",
                isError: index % 2 == 0
            ))
        }
        let summary = await session.reportSnapshot(includeActions: false)
        XCTAssertTrue(summary.actions.isEmpty)
        XCTAssertEqual(summary.actionCount, 1000)
        XCTAssertEqual(summary.errorCount, 500)
    }
}

// swiftlint:enable multiline_arguments
