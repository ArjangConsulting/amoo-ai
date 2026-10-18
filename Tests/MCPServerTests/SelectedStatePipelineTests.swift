// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
@testable import MCPServer
@testable import SessionCompiler
import StudioProtocol
@testable import TestCodeGenerator
import TestSession
import XCTest

/// Selected-state and combined-selector fidelity from recording to generated source: what an agent
/// asserts live must reach `report.json`, the compiled plan and the XCUITest unchanged, and what it
/// only observes must never turn into an assertion.
final class SelectedStatePipelineTests: XCTestCase {
    private static let dayID = "calendar.day.2026-10-30"
    private static let otherID = "calendar.day.2026-10-31"

    private struct FixedDriverBootstrapper: SessionBootstrapper {
        let driver: CalendarDriver

        func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
            BootstrapResult(driver: driver, deviceID: "sim", platform: request.platform, cleanup: {})
        }

        func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
            []
        }
    }

    /// Two dates; `selected` is the state of the first, and tapping either toggles it.
    private func calendar(selected: Bool) -> CalendarDriver {
        CalendarDriver([
            ElementInfo(
                id: Self.dayID, label: "Friday, October 30, 2026, Range start", type: .button,
                frame: Rect(x: 0, y: 100, width: 40, height: 40), isSelected: selected
            ),
            ElementInfo(
                id: Self.otherID, label: "Saturday, October 31, 2026", type: .button,
                frame: Rect(x: 50, y: 100, width: 40, height: 40), isSelected: false
            )
        ])
    }

    /// Records `calls` against a live executor, ends the session and returns the reloaded report.
    private func record(
        _ calls: [(String, [String: String])],
        driver: CalendarDriver
    ) async throws -> SessionReport {
        let manager = SessionManager(bootstrapper: FixedDriverBootstrapper(driver: driver))
        let session = try await manager.startSession(appID: "com.example.calendar", platform: .ios)
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        for (tool, arguments) in calls {
            let result = await executor.execute(
                toolName: tool,
                arguments: arguments.merging(["session_id": session.id, "timeout_ms": "100"]) { current, _ in current }
            )
            XCTAssertFalse(result.isError, "\(tool): \(result.content)")
        }
        let report = await SessionReport.make(from: session)
        try await manager.endSession(session.id)
        // The serialized report is what `generate plan` reads back, so go through its codec.
        let data = try SessionReport.makeJSONEncoder().encode(report)
        return try SessionReport.makeJSONDecoder().decode(SessionReport.self, from: data)
    }

    private func plan(_ report: SessionReport) throws -> CompileSessionToPlanResult {
        try SessionPlanCompiler.compile(report: report, testName: "Selection", testDescription: nil)
    }

    private func operations(_ result: CompileSessionToPlanResult) -> [StudioToolOperation] {
        result.studioTest.compiledPlan?.toolOperations ?? []
    }

    // MARK: - Recording → report → plan

    func testPositiveAndNegativeSelectedAssertionsSurviveReportSerializationAndCompilation() async throws {
        let driver = calendar(selected: true)
        let report = try await record([
            ("assert_selected", ["id": Self.dayID, "expected": "true"]),
            ("assert_selected", ["id": Self.otherID, "expected": "false"]),
            ("assert_selected", ["id": Self.dayID])
        ], driver: driver)

        XCTAssertEqual(report.actions.map(\.toolName), ["assert_selected", "assert_selected", "assert_selected"])
        XCTAssertTrue(report.actions.allSatisfy { $0.intent == .assertion })
        XCTAssertEqual(
            report.actions.map { $0.arguments["expected"] },
            ["true", "false", "true"],
            "defaults are explicit"
        )

        let compiled = try plan(report)
        let selected = operations(compiled).filter { $0.tool == "assert_selected" }
        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(selected.map { $0.arguments["expected"] }, ["true", "false", "true"])
        XCTAssertEqual(selected.map { $0.arguments["id"] }, [Self.dayID, Self.otherID, Self.dayID])
        XCTAssertFalse(operations(compiled).contains { $0.tool == "assert_visible" }, "never degraded to visibility")
        XCTAssertTrue(compiled.studioTest.compiledPlan?.excludedWarnings.isEmpty == true)
        XCTAssertEqual(
            compiled.studioTest.steps.map(\.instruction).filter { $0.contains("selected") }.count, 3
        )

        let preserved = compiled.warnings.filter { $0.category == .assertionPreserved }
        XCTAssertEqual(preserved.count, 3)
        XCTAssertEqual(
            preserved.map(\.state),
            ["expected selected=true", "expected selected=false", "expected selected=true"]
        )
        XCTAssertEqual(preserved.first?.selector, "id=\(Self.dayID)")
    }

    func testGenerationEmitsPositiveAndNegativeSelectionChecks() async throws {
        let report = try await record([
            ("tap_element", ["id": Self.dayID]),
            ("assert_selected", ["id": Self.dayID, "expected": "true"]),
            ("assert_selected", ["id": Self.otherID, "expected": "false"])
        ], driver: calendar(selected: false))
        let source = try XCUITestEmitter().generate(plan(report).studioTest).source

        XCTAssertTrue(source.contains("expected: true, named:"), source)
        XCTAssertTrue(source.contains("expected: false, named:"), source)
        XCTAssertTrue(source.contains("wait(for: \\.isSelected, toEqual: expected"), source)
        // Existence is awaited first, so an absent element and an unselected one fail differently.
        let existence = try XCTUnwrap(source.range(of: "waitForExistence("))
        let selection = try XCTUnwrap(source.range(
            of: "waitForSelection(",
            range: existence.upperBound ..< source.endIndex
        ))
        XCTAssertLessThan(existence.lowerBound, selection.lowerBound)
    }

    // MARK: - Observations are not assertions

    func testObservedSelectedStateIsNotConvertedIntoAnAssertionAndIsFlaggedAsNotAsserted() async throws {
        // Action 0 is an inspection that is not followed by a state change, so it is left out; action 1
        // precedes the tap, so it is approximated as a visibility assertion; both read selected state.
        let report = try await record([
            ("find_elements", ["id": Self.dayID]),
            ("find_elements", ["id": Self.otherID]),
            ("tap_element", ["id": Self.otherID])
        ], driver: calendar(selected: true))
        XCTAssertEqual(report.actions[0].observedElements.first?.isSelected, true, "the observation keeps the state")

        let compiled = try plan(report)
        XCTAssertFalse(operations(compiled).contains { $0.tool == "assert_selected" })

        let notAsserted = compiled.warnings.filter { $0.category == .selectedStateNotAsserted }
        XCTAssertEqual(notAsserted.map(\.actionIndex), [0], "only the observation that saw a selection")
        XCTAssertEqual(notAsserted.first?.state, "\(Self.dayID): selected=true")
        XCTAssertTrue(notAsserted.allSatisfy { $0.reason.contains("assert_selected") })

        // The pre-transition inspection is still the visibility guess it always was, named as such.
        let approximated = compiled.warnings.filter { $0.category == .observationApproximated }
        XCTAssertEqual(approximated.map(\.actionIndex), [1])
        XCTAssertEqual(approximated.first?.selector, "id=\(Self.otherID)")
        let omitted = compiled.warnings.filter { $0.category == .inspectionOmitted }
        XCTAssertEqual(omitted.map(\.actionIndex), [0])
    }

    // MARK: - Explicit assertions never weaken silently

    func testAnExplicitSelectedAssertionThatCannotBePreservedIsUnsupportedNotVisibility() throws {
        let action = SessionAction(
            timestamp: Date(), toolName: "assert_selected",
            arguments: ["id": Self.dayID, "expected": "maybe"], result: "ok", isError: false, intent: .assertion
        )
        let report = SessionReport(
            sessionID: "s", appID: "com.example", deviceID: "d", platform: "ios",
            startedAt: Date(), endedAt: Date(), durationSeconds: 1, actionCount: 1, errorCount: 0,
            isActive: false, actions: [action]
        )
        let compiled = try plan(report)
        XCTAssertTrue(operations(compiled).isEmpty, "not carried as a weaker operation")
        let warning = try XCTUnwrap(compiled.warnings.first)
        XCTAssertEqual(warning.kind, .excluded)
        XCTAssertEqual(warning.category, .assertionUnsupported)
        XCTAssertEqual(warning.actionIndex, 0)
        XCTAssertEqual(warning.selector, "id=\(Self.dayID)")
        XCTAssertFalse(compiled.studioTest.compiledPlan?.excludedWarnings.isEmpty ?? true, "blocks generation")
    }

    func testADescriptionBackedAssertionIsMarkedWeakenedBecauseItIsAGuess() throws {
        let report = SessionReport(
            sessionID: "s", appID: "com.example", deviceID: "d", platform: "ios",
            startedAt: Date(), endedAt: Date(), durationSeconds: 1, actionCount: 1, errorCount: 0,
            isActive: false, actions: [SessionAction(
                timestamp: Date(), toolName: "assert_selected",
                arguments: ["description": "the start date", "expected": "true"],
                result: "ok", isError: false, intent: .assertion
            )]
        )
        let compiled = try plan(report)
        XCTAssertEqual(operations(compiled).first?.tool, "assert_selected")
        XCTAssertEqual(compiled.warnings.first { $0.kind == .approximate }?.category, .assertionWeakened)
    }

    // MARK: - Selector constraints through the pipeline

    func testCombinedIdentifierAndTextSurviveEveryStage() async throws {
        let report = try await record([
            ("assert_visible", ["id": Self.dayID, "contains_text": "Range start"])
        ], driver: calendar(selected: true))
        XCTAssertEqual(report.actions[0].arguments["id"], Self.dayID)
        XCTAssertEqual(report.actions[0].arguments["contains_text"], "Range start")

        let compiled = try plan(report)
        let operation = try XCTUnwrap(operations(compiled).first)
        XCTAssertEqual(operation.arguments["id"], Self.dayID)
        XCTAssertEqual(operation.arguments["contains_text"], "Range start")
        XCTAssertFalse(compiled.warnings.contains { $0.category == .selectorConstraintDiscarded })
        XCTAssertEqual(
            compiled.warnings.first { $0.category == .assertionPreserved }?.selector,
            "id=\(Self.dayID), contains_text=Range start"
        )

        let xcui = try XCUITestEmitter().generate(compiled.studioTest).source
        XCTAssertTrue(xcui.contains("""
        .matching(identifier: "\(Self.dayID)").matching(NSPredicate(format: "label CONTAINS %@", "Range start"))
        """), xcui)

        let espresso = try EspressoEmitter().generate(compiled.studioTest).source
        XCTAssertTrue(espresso.contains("allOf(anyOf(hasResourceEntryName(\"\(Self.dayID)\")"), espresso)
        XCTAssertTrue(espresso.contains("containsString(\"Range start\")"), espresso)
        let compose = try ComposeEspressoEmitter().generate(compiled.studioTest).source
        XCTAssertTrue(
            compose.contains("hasTestTag(\"\(Self.dayID)\") and hasText(\"Range start\", substring = true)"),
            compose
        )
    }

    func testASelectorFieldThePlanCannotCarryIsReportedNotDropped() throws {
        let report = SessionReport(
            sessionID: "s", appID: "com.example", deviceID: "d", platform: "ios",
            startedAt: Date(), endedAt: Date(), durationSeconds: 1, actionCount: 1, errorCount: 0,
            isActive: false, actions: [SessionAction(
                timestamp: Date(), toolName: "assert_visible",
                arguments: ["id": Self.dayID, "description": "the start date"],
                result: "ok", isError: false, intent: .assertion
            )]
        )
        let compiled = try plan(report)
        let warning = try XCTUnwrap(compiled.warnings.first { $0.category == .selectorConstraintDiscarded })
        XCTAssertEqual(warning.actionIndex, 0)
        XCTAssertEqual(warning.kind, .approximate)
        XCTAssertTrue(warning.reason.contains("description"), warning.reason)
        XCTAssertEqual(warning.selector, "id=\(Self.dayID), description=the start date")
    }

    // MARK: - Mutation: removing the interaction must remove a passing path

    /// The recorded flow's selection checks stay in the generated source when its taps are deleted,
    /// so the mutated test asserts a selection that never happened and fails, where the old
    /// visibility-only output kept passing.
    func testDeletingTheSelectionTapsLeavesAssertionsThatCanOnlyPassIfTheTapsRan() async throws {
        let report = try await record([
            ("tap_element", ["id": Self.dayID]),
            ("assert_selected", ["id": Self.dayID, "expected": "true"]),
            ("tap_element", ["id": Self.otherID]),
            ("assert_selected", ["id": Self.otherID, "expected": "true"])
        ], driver: calendar(selected: false))
        let generated = try XCUITestEmitter().generate(plan(report).studioTest).source
        // Only the test method: the helpers above it tap too.
        let source = try XCTUnwrap(generated.range(of: "func testSelection")).lowerBound
            .samePosition(in: generated).map { String(generated[$0...]) } ?? generated

        let taps = source.components(separatedBy: ".tap()").count - 1
        let selectionChecks = source.components(separatedBy: "expected: true").count - 1
        XCTAssertEqual(taps, 2)
        XCTAssertEqual(selectionChecks, 2, "one explicit selection check per recorded selection")
        let mutated = source.replacingOccurrences(of: ".tap()", with: ".exists")
        XCTAssertFalse(mutated.contains(".tap()"))
        XCTAssertEqual(mutated.components(separatedBy: "expected: true").count - 1, 2, "assertions remain")
    }
}

// swiftlint:enable multiline_arguments
