// SwiftFormat compact wrapping conflicts with argument layout lint.
// swiftlint:disable multiline_arguments
@testable import AmooCore
import Foundation
import TestCommons
import XCTest

@MainActor
private final class FakeVoiceOver: VoiceOverControlling {
    var isEnabled = false
    var moves = 0
    var position = 0
    var changes: [Bool] = []
    var failMove: Int?
    var failCleanup = false
    var ignoreStateChanges = false
    var afterMove: () -> Void = {}
    func setEnabled(_ enabled: Bool) throws {
        if !enabled, failCleanup {
            throw CocoaError(.fileWriteUnknown)
        }
        if !ignoreStateChanges {
            isEnabled = enabled
        }
        changes.append(enabled)
    }

    func move(direction: String) throws -> String {
        moves += 1
        if moves == failMove {
            throw CocoaError(.fileReadUnknown)
        }
        position += direction == "forward" ? 1 : -1
        afterMove()
        return "Item \(position)"
    }
}

final class VoiceOverTraversalTests: XCTestCase {
    @MainActor
    func testContinuousPhasesRestoreInitiallyEnabledAndDisabledStates() async throws {
        // Keep an async XCTest entry point for actor-isolated test discovery on Linux.
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for original in [true, false] {
            let service = FakeVoiceOver()
            service.isEnabled = original
            let journal = VoiceOverRecoveryJournal(url: scratch.url.appending(path: "recovery.json"))
            let result = VoiceOverTraversal.run(
                appID: "com.test", phases: [
                    .init(steps: 3, direction: "forward"),
                    .init(steps: 3, direction: "backward")
                ],
                service: service, journal: journal, isTargetForeground: { true }, isCancelled: { false }
            )
            XCTAssertEqual(result.executionStatus, "succeeded")
            XCTAssertEqual(result.verdict, "notAssessed")
            XCTAssertEqual(result.cleanupStatus, "restored")
            XCTAssertEqual(result.evaluatedChecks.count, 2)
            XCTAssertEqual(service.position, 0)
            XCTAssertEqual(service.changes, original ? [] : [true, false])
            XCTAssertNil(try journal.load())
        }
    }

    @MainActor
    func testCancellationDeadlineAndAppSwitchRetainPartialSpeechAndRestoreState() async throws {
        // Keep an async XCTest entry point for actor-isolated test discovery on Linux.
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for failure in ["cancel", "deadline", "app"] {
            let service = FakeVoiceOver()
            var cancelled = false
            var foreground = true
            var now: TimeInterval = 0
            service.afterMove = {
                cancelled = failure == "cancel"
                foreground = failure != "app"
                now = failure == "deadline" ? 100 : 0
            }
            let result = VoiceOverTraversal.run(
                appID: "com.test", phases: [.init(steps: 3, direction: "forward")], service: service,
                journal: .init(url: scratch.url.appending(path: "recovery.json")),
                isTargetForeground: { foreground }, isCancelled: { cancelled }, uptime: { now }
            )
            XCTAssertEqual(result.executionStatus, "failed", failure)
            XCTAssertEqual(result.cleanupStatus, "restored", failure)
            XCTAssertEqual(result.utterances, ["Item 1"], failure)
            XCTAssertTrue(result.evaluatedChecks.isEmpty)
            XCTAssertFalse(service.isEnabled)
        }
    }

    @MainActor
    func testNavigationAndCleanupFailuresKeepRecoveryMarkerUntilRestartRecovery() async throws {
        // Keep an async XCTest entry point for actor-isolated test discovery on Linux.
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = FakeVoiceOver()
        service.failMove = 2
        service.failCleanup = true
        let journal = VoiceOverRecoveryJournal(url: scratch.url.appending(path: "recovery.json"))
        let result = VoiceOverTraversal.run(
            appID: "com.test", phases: [.init(steps: 3, direction: "forward")], service: service,
            journal: journal, isTargetForeground: { true }, isCancelled: { false }
        )
        XCTAssertEqual(result.executionStatus, "failed")
        XCTAssertEqual(result.cleanupStatus, "failed")
        XCTAssertEqual(result.utterances.count, 1)
        XCTAssertEqual(try journal.load()?.completedMoves, 1)
        let contents = try String(contentsOf: journal.url, encoding: .utf8)
        XCTAssertFalse(contents.contains("Item"))
        service.failCleanup = false
        try VoiceOverTraversal.recover(service: service, journal: journal)
        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(try journal.load())
    }

    @MainActor
    func testUnrecoverableMarkerBlocksNewTraversalWithoutOverwritingOriginalState() async throws {
        // Keep an async XCTest entry point for actor-isolated test discovery on Linux.
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = FakeVoiceOver()
        service.isEnabled = true
        service.failCleanup = true
        let journal = VoiceOverRecoveryJournal(url: scratch.url.appending(path: "recovery.json"))
        try journal.save(.init(originalEnabled: false, appID: "previous.app", completedMoves: 2, startedAt: Date()))
        let result = VoiceOverTraversal.run(
            appID: "new.app", phases: [.init(steps: 1, direction: "forward")], service: service,
            journal: journal, isTargetForeground: { true }, isCancelled: { false }
        )
        XCTAssertEqual(result.executionStatus, "failed")
        XCTAssertEqual(service.moves, 0)
        XCTAssertEqual(try journal.load()?.appID, "previous.app")
    }

    @MainActor
    func testRecoveryVerifiesInitiallyEnabledStateBeforeClearingMarker() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = FakeVoiceOver()
        service.ignoreStateChanges = true
        let journal = VoiceOverRecoveryJournal(url: scratch.url.appending(path: "recovery.json"))
        try journal.save(.init(originalEnabled: true, appID: "previous.app", completedMoves: 1, startedAt: Date()))
        XCTAssertThrowsError(try VoiceOverTraversal.recover(service: service, journal: journal))
        XCTAssertNotNil(try journal.load(), "A successful setter is insufficient without a verified state")
        service.ignoreStateChanges = false
        let recovered = try VoiceOverTraversal.recover(service: service, journal: journal)
        XCTAssertEqual(recovered?.originalEnabled, true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertNil(try journal.load())
    }

    @MainActor
    func testInvalidRequestDoesNotClaimPendingCleanupOrChangeState() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let journal = VoiceOverRecoveryJournal(url: scratch.url.appending(path: "recovery.json"))
        let service = FakeVoiceOver()
        for budget in [TimeInterval.nan, .infinity, 0, -1] {
            let result = VoiceOverTraversal.run(
                appID: "com.test", phases: [.init(steps: 1, direction: "forward")], service: service,
                journal: journal, isTargetForeground: { true }, isCancelled: { false }, budget: budget
            )
            XCTAssertEqual(result.executionStatus, "failed")
            XCTAssertNil(result.cleanupError)
            XCTAssertTrue(service.changes.isEmpty)
            XCTAssertNil(try journal.load())
        }
    }

    @MainActor
    func testUnverifiedEnableCannotStartTraversal() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = FakeVoiceOver()
        service.ignoreStateChanges = true
        let journal = VoiceOverRecoveryJournal(url: scratch.url.appending(path: "recovery.json"))
        let result = VoiceOverTraversal.run(
            appID: "com.test", phases: [.init(steps: 1, direction: "forward")], service: service,
            journal: journal, isTargetForeground: { true }, isCancelled: { false }
        )
        XCTAssertEqual(result.executionStatus, "failed")
        XCTAssertEqual(result.cleanupStatus, "restored")
        XCTAssertEqual(service.moves, 0)
        XCTAssertNil(try journal.load())
    }
}

// swiftlint:enable multiline_arguments
