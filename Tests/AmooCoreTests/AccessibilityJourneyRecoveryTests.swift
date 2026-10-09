// SwiftFormat compact wrapping conflicts with argument-layout lint.
// swiftlint:disable multiline_arguments
@testable import AmooCore
import Foundation
import TestCommons
import XCTest

/// Recovery timing runs on a virtual clock: polls advance it only through the injected sleep.
final class AccessibilityJourneyRecoveryTests: XCTestCase {
    private func transition(timeoutMS: Int) -> AccessibilityJourneyStep {
        .init(
            id: "next-page",
            kind: .transition,
            element: .init(id: "next", name: "Next"),
            action: .doubleTap,
            before: .init(equals: "Next, button"),
            after: .init(elementID: "page", equals: "Page 2"),
            destination: .init(id: "page", name: "Page 2"),
            recoveryTimeoutMS: timeoutMS
        )
    }

    @MainActor
    private func run(
        _ steps: [AccessibilityJourneyStep],
        _ service: JourneyControl,
        _ root: URL,
        clock: VirtualClock = VirtualClock()
    ) -> AccessibilityInspection {
        AccessibilityJourneyRunner.run(
            appID: "com.test", journey: .init(id: "recovery", steps: steps), service: service,
            journal: .init(url: root.appending(path: "marker.json")),
            isTargetForeground: { true }, isCancelled: { false },
            uptime: { clock.now }, sleep: { clock.advance($0) }
        )
    }

    @MainActor
    func testFocusSettlingAfterTheLastRegularPollStillRecovers() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        service.recoverFocus = false
        let clock = VirtualClock()
        service.beforeSpeechRead = {
            if clock.now >= 0.9 {
                service.speech = "Page 2"
            }
        }
        let result = run([transition(timeoutMS: 1000)], service, scratch.url, clock: clock)
        XCTAssertEqual(result.verdict, "pass")
        XCTAssertEqual(result.journey?.checks.last?.outcome, .pass)
        XCTAssertEqual(result.utterances, ["Next, button", "Unexpected focus", "Page 2"], "Repeated polls kept once")
        XCTAssertLessThanOrEqual(clock.now, 1.0)
    }

    @MainActor
    func testMismatchFailsOnlyFromAReadAtTheDeadline() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        service.recoverFocus = false
        let clock = VirtualClock()
        var readTimes: [TimeInterval] = []
        service.beforeSpeechRead = { readTimes.append(clock.now) }
        let result = run([transition(timeoutMS: 1000)], service, scratch.url, clock: clock)
        XCTAssertEqual(result.verdict, "fail")
        XCTAssertEqual(result.journey?.checks.last?.outcome, .fail)
        XCTAssertEqual(result.journey?.checks.last?.actual, "Unexpected focus")
        XCTAssertEqual(readTimes.last, 1.0, "The failing read starts at the deadline")
        XCTAssertEqual(readTimes.dropLast().last, 0.99, "The previous read is timed to finish in bound")
        XCTAssertEqual(result.utterances, ["Next, button", "Unexpected focus"])
    }

    @MainActor
    func testEarlierTruncationDoesNotHideASeekFailure() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        service.metadata["next"]?[0].name = String(repeating: "x", count: 5000)
        let result = run([
            .init(id: "semantics", kind: .element, element: .init(id: "next", role: "Button")),
            .init(id: "anchor", kind: .seek, direction: "forward", maxMoves: 1, speech: [.init(equals: "Missing")])
        ], service, scratch.url)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.journey?.checks.first { $0.id == "anchor.seek" }?.outcome, .fail)
        XCTAssertEqual(result.verdict, "fail")
    }

    @MainActor
    func testMissingDestinationIsNotReportedAsAlreadyMatched() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        service.metadata["page"] = nil
        service.actionChangesDestination = false
        let result = run([transition(timeoutMS: 0)], service, scratch.url)
        let destination = try XCTUnwrap(result.journey?.checks.first { $0.id == "next-page.destination" })
        XCTAssertEqual(destination.outcome, .fail)
        XCTAssertEqual(destination.reason, "Destination did not match authored metadata after the gesture")
    }

    @MainActor
    func testRecoveryPollsCannotTruncateDecisiveEvidence() async {
        await Task.yield()
        var result = AccessibilityInspection(status: "observed", provider: "authoredAccessibilityJourney")
        result.journey = .init(id: "budget", checkpoints: [.init(id: "step")])
        for index in 0 ..< 200 {
            AccessibilityJourneyRunner.captureRecoveryRead("poll \(index)", decisive: false, result: &result)
        }
        XCTAssertEqual(result.utterances.count, AccessibilityJourneyRunner.recoveryPollBudget)
        XCTAssertFalse(result.truncated)
        AccessibilityJourneyRunner.captureRecoveryRead("final", decisive: true, result: &result)
        XCTAssertEqual(result.utterances.last, "final")
        XCTAssertFalse(result.truncated)
    }
}

/// Monotonic test clock; rounding to whole milliseconds keeps sums such as 0.99 + 0.01 exact.
final class VirtualClock: @unchecked Sendable {
    private(set) var now: TimeInterval = 0

    func advance(_ interval: TimeInterval) {
        now = ((now + interval) * 1000).rounded() / 1000
    }
}

// swiftlint:enable multiline_arguments
