// SwiftFormat compact wrapping conflicts with argument-layout lint.
// swiftlint:disable multiline_arguments
@testable import AmooCore
import Foundation
import TestCommons
import XCTest

@MainActor
final class JourneyControl: AccessibilityJourneyControlling {
    var isEnabled = false
    var changes: [Bool] = []
    var moves = 0
    var actions = 0
    var speech = "Next, button"
    var moveSpeech = ["First", "Second", "Next, button"]
    var metadata: [String: [AccessibilityElementEvidence]] = [
        "next": [.init(id: "next", name: "Next", role: "Button", enabled: true, selected: false)],
        "page": [.init(id: "page", name: "Page 1")]
    ]
    var recoverFocus = true
    var actionChangesDestination = true
    var failCleanup = false
    var afterMove: () -> Void = {}
    var speechReads = 0
    var beforeSpeechRead: () -> Void = {}

    func setEnabled(_ enabled: Bool) throws {
        if !enabled, failCleanup {
            throw CocoaError(.fileWriteUnknown)
        }
        isEnabled = enabled
        changes.append(enabled)
    }

    func move(direction: String) throws -> String {
        let index = direction == "forward" ? moves : moveSpeech.count - moves - 1
        moves += 1
        speech = moveSpeech[max(0, min(index, moveSpeech.count - 1))]
        afterMove()
        return speech
    }

    func currentSpeech() throws -> String {
        speechReads += 1
        beforeSpeechRead()
        return speech
    }

    func elements(id: String) throws -> [AccessibilityElementEvidence] {
        metadata[id] ?? []
    }

    func perform(action _: AccessibilityJourneyStep.Action, elementID _: String) throws {
        actions += 1
        if actionChangesDestination {
            metadata["page"] = [.init(id: "page", name: "Page 2")]
        }
        speech = recoverFocus ? "Page 2" : "Unexpected focus"
    }
}

final class AccessibilityJourneyTests: XCTestCase {
    private func journey() -> AccessibilityJourney {
        .init(id: "paging", steps: [
            .init(
                id: "semantics",
                kind: .element,
                element: .init(id: "next", name: "Next", role: "Button", enabled: true, selected: false)
            ),
            .init(id: "order", kind: .order, direction: "forward", speech: [
                .init(elementID: "first", equals: "First"), .init(elementID: "second", equals: "Second")
            ]),
            .init(
                id: "anchor",
                kind: .seek,
                direction: "forward",
                maxMoves: 1,
                speech: [.init(elementID: "next", equals: "Next, button")]
            ),
            .init(
                id: "next-page",
                kind: .transition,
                element: .init(id: "next", name: "Next"),
                action: .doubleTap,
                before: .init(equals: "Next, button"),
                after: .init(elementID: "page", equals: "Page 2"),
                destination: .init(id: "page", name: "Page 2"),
                recoveryTimeoutMS: 0
            )
        ])
    }

    @MainActor
    func testCleanControlsPassWithOneServiceLifetimeAndNoRecoveryMoves() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for original in [false, true] {
            let service = JourneyControl()
            service.isEnabled = original
            let result = run(journey(), service, scratch.url)
            XCTAssertEqual(result.executionStatus, "succeeded")
            XCTAssertEqual(result.verdict, "pass")
            XCTAssertEqual(result.cleanupStatus, "restored")
            XCTAssertEqual(result.evaluatedChecks, result.requestedChecks)
            XCTAssertEqual(service.moves, 3, "Recovery must not repair focus by moving")
            XCTAssertEqual(service.actions, 1)
            XCTAssertEqual(service.changes, original ? [] : [true, false])
            XCTAssertEqual(result.journey?.checkpoints.last?.utterances, ["Next, button", "Page 2"])
            XCTAssertEqual(
                result.journey?.checkpoints.last?.elementCaptures?.map(\.stage),
                ["targetBefore", "destinationBefore", "destinationAfter"]
            )
            XCTAssertEqual(try JSONDecoder().decode(
                AccessibilityInspection.self,
                from: JSONEncoder().encode(result)
            ), result)
        }
    }

    @MainActor
    func testSeededNameRoleStateOrderAndRecoveryConcernsHaveScopedFailures() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for seed in ["name", "role", "enabled", "selected", "order", "recovery"] {
            let service = JourneyControl()
            switch seed {
            case "name": service.metadata["next"]?[0].name = ""
            case "role": service.metadata["next"]?[0].role = "StaticText"
            case "enabled": service.metadata["next"]?[0].enabled = false
            case "selected": service.metadata["next"]?[0].selected = true
            case "order": service.moveSpeech = ["Second", "First", "Next, button"]
            case "recovery": service.recoverFocus = false
            default: XCTFail("Unknown seed")
            }
            let result = run(journey(), service, scratch.url)
            XCTAssertEqual(result.verdict, "fail", seed)
            XCTAssertEqual(result.executionStatus, "succeeded", seed)
            XCTAssertEqual(result.cleanupStatus, "restored", seed)
            let failure = try XCTUnwrap(result.journey?.checks.first { $0.outcome == .fail })
            XCTAssertFalse(failure.checkpointID.isEmpty)
            XCTAssertNotNil(failure.elementID, seed)
            if seed == "recovery" {
                XCTAssertEqual(failure.transitionID, "next-page")
                XCTAssertEqual(failure.actual, "Unexpected focus")
            }
            if seed == "order" {
                XCTAssertEqual(service.actions, 0, "Failed order cannot reach later transition")
            }
        }
    }

    @MainActor
    func testRecoveryWaitPreservesIntermediateSpeechWithoutRepairMoves() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        service.recoverFocus = false
        service.beforeSpeechRead = {
            if service.speechReads == 3 {
                service.speech = "Page 2"
            }
        }
        var transition = try XCTUnwrap(journey().steps.last)
        transition.recoveryTimeoutMS = 1000
        let result = run(.init(id: "delayed", steps: [transition]), service, scratch.url)
        XCTAssertEqual(result.verdict, "pass")
        XCTAssertEqual(result.utterances, ["Next, button", "Unexpected focus", "Page 2"])
        XCTAssertEqual(service.moves, 0)
        XCTAssertEqual(service.actions, 1)
        XCTAssertEqual(service.changes, [true, false])
    }

    @MainActor
    func testCancellationDuringRecoveryRetainsEvidenceAndRestoresVoiceOver() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        service.recoverFocus = false
        var cancelled = false
        service.beforeSpeechRead = {
            if service.speechReads == 2 {
                cancelled = true
            }
        }
        let result = try AccessibilityJourneyRunner.run(
            appID: "com.test", journey: .init(id: "cancelled", steps: [XCTUnwrap(journey().steps.last)]),
            service: service, journal: .init(url: scratch.url.appending(path: "marker.json")),
            isTargetForeground: { true }, isCancelled: { cancelled }
        )
        XCTAssertEqual(result.executionStatus, "failed")
        XCTAssertEqual(result.cleanupStatus, "restored")
        XCTAssertEqual(result.journey?.checks.last?.outcome, .notEvaluated)
        XCTAssertEqual(result.utterances, ["Next, button", "Unexpected focus"])
        XCTAssertEqual(service.moves, 0)
    }

    @MainActor
    func testSpeechArrivingAfterRecoveryDeadlineCannotPass() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        var clock: TimeInterval = 0
        service.beforeSpeechRead = {
            if service.speechReads == 2 {
                clock = 2
            }
        }
        var transition = try XCTUnwrap(journey().steps.last)
        transition.recoveryTimeoutMS = 1000
        let result = AccessibilityJourneyRunner.run(
            appID: "com.test", journey: .init(id: "late", steps: [transition]), service: service,
            journal: .init(url: scratch.url.appending(path: "marker.json")),
            isTargetForeground: { true }, isCancelled: { false }, uptime: { clock }
        )
        XCTAssertEqual(result.verdict, "notAssessed")
        XCTAssertEqual(result.cleanupStatus, "restored")
        XCTAssertEqual(result.journey?.checks.last?.outcome, .notEvaluated)
        XCTAssertEqual(result.journey?.checks.last?.actual, "Page 2")
    }

    @MainActor
    func testMissingStateAndDuplicateTargetsNeverPassOrActivate() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        service.metadata["next"]?[0].selected = nil
        var result = run(.init(id: "unknown", steps: [journey().steps[0]]), service, scratch.url)
        XCTAssertEqual(result.verdict, "notAssessed")
        XCTAssertEqual(result.journey?.checks.last?.outcome, .unsupported)
        XCTAssertEqual(result.notEvaluatedReasons.keys.sorted(), ["semantics.selected"])
        service.metadata["next"]?.append(.init(id: "next", name: "Next"))
        result = try run(.init(id: "duplicate", steps: [XCTUnwrap(journey().steps.last)]), service, scratch.url)
        XCTAssertEqual(result.verdict, "notAssessed")
        XCTAssertEqual(service.actions, 0)
        XCTAssertTrue(result.journey?.checks.contains { $0.outcome == .needsReview } == true)
    }

    @MainActor
    func testUnchangedDestinationAndWrongBeforeAnchorDoNotClaimFocusRecovery() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for seed in ["unchanged", "before"] {
            let service = JourneyControl()
            if seed == "unchanged" {
                service.metadata["page"] = [.init(id: "page", name: "Page 2")]
                service.actionChangesDestination = false
            } else {
                service.speech = "Unrelated focus"
            }
            let result = try run(.init(id: seed, steps: [XCTUnwrap(journey().steps.last)]), service, scratch.url)
            XCTAssertNotEqual(result.verdict, "pass")
            XCTAssertEqual(result.journey?.checks.last?.outcome, .notEvaluated)
            XCTAssertEqual(result.journey?.checks.last?.id, "next-page.recovery")
            XCTAssertEqual(service.moves, 0)
            XCTAssertEqual(service.actions, seed == "before" ? 0 : 1)
        }
    }

    @MainActor
    func testCancelledCheckpointKeepsPartialEvidenceAndIndependentCleanup() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        var cancelled = false
        service.afterMove = { cancelled = true }
        service.failCleanup = true
        let journal = VoiceOverRecoveryJournal(url: scratch.url.appending(path: "marker.json"))
        let result = AccessibilityJourneyRunner.run(
            appID: "com.test", journey: journey(), service: service, journal: journal,
            isTargetForeground: { true }, isCancelled: { cancelled }
        )
        XCTAssertEqual(result.executionStatus, "failed")
        XCTAssertEqual(result.verdict, "notAssessed")
        XCTAssertEqual(result.cleanupStatus, "failed")
        XCTAssertEqual(result.utterances, ["First"])
        XCTAssertEqual(service.actions, 0)
        XCTAssertEqual(try journal.load()?.completedMoves, 1)
        XCTAssertEqual(result.evaluatedChecks.count, 4)
    }

    func testInvalidSchemaMisspelledExpectationsAndBoundsAreRejected() throws {
        try journey().validate()
        let tooMany = AccessibilityJourney(id: "tooMany", steps: [
            .init(id: "seek", kind: .seek, direction: "forward", maxMoves: 30, speech: [.init(equals: "Target")]),
            .init(id: "order", kind: .order, direction: "forward", speech: [.init(equals: "Next")])
        ])
        XCTAssertThrowsError(try tooMany.validate())
        XCTAssertThrowsError(try AccessibilityJourney(id: "version", steps: journey().steps, schemaVersion: 2)
            .validate())
        for timeout in [-1, 5001] {
            var invalid = journey()
            invalid.steps[3].recoveryTimeoutMS = timeout
            XCTAssertThrowsError(try invalid.validate())
        }
        for input in [
            #"""
            {"schemaVersion":1,"id":"unknown","steps":[{"id":"s","kind":"element",
              "element":{"id":"button","name":"Button","selectd":true}}]}
            """#,
            #"""
            {"schemaVersion":1,"id":"unknown","steps":[{"id":"s","kind":"order","direction":"forward",
              "speech":[{"equals":"First","contains":"First"}]}]}
            """#
        ] {
            XCTAssertThrowsError(try AccessibilityJourney.decodeJSON(input))
        }
    }

    @MainActor
    func testInvalidJourneyCannotMutateVoiceOverOrApp() async throws {
        await Task.yield()
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let service = JourneyControl()
        let invalid = AccessibilityJourney(id: "bad", steps: [.init(
            id: "empty",
            kind: .order,
            direction: "forward",
            speech: [.init(contains: "")]
        )])
        let result = run(invalid, service, scratch.url)
        XCTAssertEqual(result.executionStatus, "failed")
        XCTAssertTrue(service.changes.isEmpty)
        XCTAssertEqual(service.actions, 0)
        XCTAssertEqual(service.moves, 0)
    }

    @MainActor
    private func run(
        _ journey: AccessibilityJourney,
        _ service: JourneyControl,
        _ root: URL
    ) -> AccessibilityInspection {
        AccessibilityJourneyRunner.run(
            appID: "com.test",
            journey: journey,
            service: service,
            journal: .init(url: root.appending(path: "marker.json")),
            isTargetForeground: { true },
            isCancelled: { false }
        )
    }
}

// swiftlint:enable multiline_arguments
