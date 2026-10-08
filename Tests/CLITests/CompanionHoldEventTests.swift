@testable import CLI
import Foundation
import XCTest

final class CompanionHoldEventTests: XCTestCase {
    func testDuplicateNotificationsFromOldRunnerCannotRestartItsReplacement() async {
        let (stream, sink) = AsyncStream.makeStream(of: HoldEvent.self)
        let previous = UUID()
        let replacement = UUID()
        sink.yield(.runnerExited(previous))
        sink.yield(.runnerUnavailable(previous))
        sink.yield(.runnerUnavailable(replacement))
        sink.finish()
        var iterator = stream.makeAsyncIterator()
        let event = await nextHoldEvent(&iterator, generation: replacement)
        XCTAssertEqual(event, .runnerUnavailable(replacement))
    }

    func testShutdownSignalIsNotDiscardedWithOldCrashNotifications() async {
        let (stream, sink) = AsyncStream.makeStream(of: HoldEvent.self)
        sink.yield(.runnerUnavailable(UUID()))
        sink.yield(.signal)
        sink.finish()
        var iterator = stream.makeAsyncIterator()
        let event = await nextHoldEvent(&iterator, generation: UUID())
        XCTAssertEqual(event, .signal)
    }
}
