@testable import CLI
import XCTest

final class CompanionHoldTests: XCTestCase {
    private actor Counter {
        private(set) var starts = 0
        private(set) var shutdowns = 0
        private(set) var exits = 0
        func start() {
            starts += 1
        }

        func shutdown() {
            shutdowns += 1
        }

        func exit() -> Int {
            exits += 1
            return exits
        }
    }

    /// A runner that dies is restarted, and the holder keeps holding until the signal.
    func testRestartsARunnerThatExits() async throws {
        let counter = Counter()
        let signals = CompanionSignalWaiter(signals: [])
        try await holdCompanion(
            start: { await counter.start() },
            announce: {},
            shutdown: { await counter.shutdown() },
            runnerExit: {
                // The first runner dies at once; the replacement lives until the signal.
                if await counter.exit() == 1 {
                    return
                }
                signals.finish()
                await CompanionSignalWaiter.never()
            },
            signals: signals
        )
        let starts = await counter.starts
        let shutdowns = await counter.shutdowns
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(shutdowns, 1)
    }

    /// A runner that keeps dying is given up on rather than restarted forever.
    func testGivesUpAfterMaxRestarts() async {
        let counter = Counter()
        do {
            try await holdCompanion(
                start: { await counter.start() },
                announce: {},
                shutdown: { await counter.shutdown() },
                runnerExit: { _ = await counter.exit() },
                maxRestarts: 2,
                signals: CompanionSignalWaiter(signals: [])
            )
            XCTFail("expected the holder to give up")
        } catch let CompanionHoldError.runnerKeepsExiting(restarts) {
            XCTAssertEqual(restarts, 2)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let starts = await counter.starts
        let shutdowns = await counter.shutdowns
        XCTAssertEqual(starts, 3)
        XCTAssertEqual(shutdowns, 1)
    }

    func testSignalShutsDownWithoutRestarting() async throws {
        let counter = Counter()
        let signals = CompanionSignalWaiter(signals: [])
        signals.finish()
        try await holdCompanion(
            start: { await counter.start() },
            announce: {},
            shutdown: { await counter.shutdown() },
            signals: signals
        )
        let starts = await counter.starts
        let shutdowns = await counter.shutdowns
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(shutdowns, 1)
    }
}
