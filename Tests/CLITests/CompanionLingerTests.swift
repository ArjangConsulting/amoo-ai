import AmooCore
@testable import CLI
import Foundation
import Synchronization
import TestCommons
import XCTest

// swiftlint:disable multiline_arguments

final class CompanionLingerTests: XCTestCase {
    private func options(token: String) -> CompanionReapOptions {
        CompanionReapOptions(platform: .ios, deviceID: "SIM", port: 22090, token: token, afterSeconds: 120)
    }

    private func linger(token: String) -> CompanionLinger {
        CompanionLinger(token: token, platform: "ios", deviceID: "SIM", port: 22090, expiresAt: Date())
    }

    func testReaperStopsACompanionNobodyPickedUp() async throws {
        let store = try CompanionLingerStore(directory: makeScratchDirectory().url)
        store.write(linger(token: "mine"))
        let waited = Mutex<[Double]>([])
        let stopped = Mutex(0)

        let outcome = await reapLingeringCompanion(
            options(token: "mine"), store: store,
            sleep: { seconds in waited.withLock { $0.append(seconds) } },
            deviceIsFree: { _ in true },
            stop: { _ in stopped.withLock { $0 += 1 } }
        )

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(waited.withLock { $0 }, [120])
        XCTAssertEqual(stopped.withLock { $0 }, 1)
        XCTAssertNil(store.read(platform: "ios", port: 22090))
    }

    func testReaperStandsDownWhenALaterServerTookTheCompanionOver() async throws {
        let store = try CompanionLingerStore(directory: makeScratchDirectory().url)
        let stopped = Mutex(0)
        let stop: @Sendable (CompanionReapOptions) async -> Void = { _ in stopped.withLock { $0 += 1 } }

        // Adopted: the new owner removed the record.
        store.write(linger(token: "mine"))
        store.claim(platform: "ios", port: 22090)
        let claimed = await reapLingeringCompanion(
            options(token: "mine"), store: store, sleep: { _ in }, deviceIsFree: { _ in true }, stop: stop
        )
        // Handed on again: the record now belongs to a later hand-off, whose own reaper decides.
        store.write(linger(token: "newer"))
        let renewed = await reapLingeringCompanion(
            options(token: "mine"), store: store, sleep: { _ in }, deviceIsFree: { _ in true }, stop: stop
        )

        XCTAssertEqual(claimed, .superseded)
        XCTAssertEqual(renewed, .superseded)
        XCTAssertEqual(stopped.withLock { $0 }, 0)
        XCTAssertEqual(store.read(platform: "ios", port: 22090)?.token, "newer")
    }

    func testReaperLeavesACompanionWhoseDeviceASessionIsDriving() async throws {
        let store = try CompanionLingerStore(directory: makeScratchDirectory().url)
        store.write(linger(token: "mine"))
        let stopped = Mutex(0)

        let outcome = await reapLingeringCompanion(
            options(token: "mine"), store: store, sleep: { _ in }, deviceIsFree: { _ in false },
            stop: { _ in stopped.withLock { $0 += 1 } }
        )

        XCTAssertEqual(outcome, .inUse)
        XCTAssertEqual(stopped.withLock { $0 }, 0)
    }

    func testHandOffRecordsTheCompanionAndStartsItsReaperOrReportsThatItCouldNot() async throws {
        let store = try CompanionLingerStore(directory: makeScratchDirectory().url)
        let spawned = Mutex<[[String]]>([])
        let hooks = CompanionLingerHooks(
            executablePath: { "/opt/amoo" }, spawn: { arguments in spawned.withLock { $0.append(arguments) } },
            store: store
        )

        let left = await leaveCompanionRunning(
            platform: "ios",
            deviceID: "SIM",
            port: 22090,
            seconds: 120,
            hooks: hooks
        )

        XCTAssertTrue(left)
        let record = try XCTUnwrap(store.read(platform: "ios", port: 22090))
        let arguments = try XCTUnwrap(spawned.withLock { $0 }.first)
        XCTAssertEqual(CompanionReapOptions.parse(Array(arguments.dropFirst(3))), CompanionReapOptions(
            platform: .ios, deviceID: "SIM", port: 22090, token: record.token, afterSeconds: 120
        ))
        XCTAssertEqual(Array(arguments.prefix(3)), ["/opt/amoo", "companion", "reap"])

        // No window, or no reaper: the caller must stop the companion itself.
        let noWindow = await leaveCompanionRunning(platform: "ios", deviceID: "SIM", port: 1, seconds: 0, hooks: hooks)
        var failing = hooks
        failing.spawn = { _ in throw CocoaError(.fileNoSuchFile) }
        let noReaper = await leaveCompanionRunning(
            platform: "ios",
            deviceID: "SIM",
            port: 2,
            seconds: 120,
            hooks: failing
        )
        XCTAssertFalse(noWindow)
        XCTAssertFalse(noReaper)
        XCTAssertNil(store.read(platform: "ios", port: 2))
        XCTAssertNil(CompanionReapOptions.parse(["--platform", "ios", "--port"]))
    }
}

// swiftlint:enable multiline_arguments
