import Foundation
@testable import MCPServer
@testable import SessionCompiler
import StudioProtocol
import TestCodeGenerator
import TestSession
import XCTest

/// A deterministic, repository-owned end-to-end fixture for the recording -> plan -> generated-test
/// pipeline. Unlike `IOSSessionCodegenRegressionTests` (which leans on a host app's skip-onboarding
/// / reset-state launch environment already containing the task under test), this scenario is
/// self-contained: it **adds** the row it later deletes, so it does not depend on any app-specific
/// seeded state.
///
/// Scenario (all steps are amoo MCP tool calls):
///
///   start clean -> add "Laundry" -> assert visible -> delete "Laundry" (find_elements ->
///   swipe_in_direction with the resolved row id -> tap Delete) -> assert absent ->
///   add "Laundry" again -> assert visible
///
/// Guards: no required action is dropped, `amoo generate test` succeeds **without**
/// `--allow-incomplete`, the generated XCTest carries semantic assertions for both mutations, the
/// swipe is element-scoped (`laundryTaskRow.swipeLeft()`, never a UUID-derived name), the picker
/// option and the catalog row get distinct semantic names (never `laundry` / `laundry2`), the launch
/// environment is reproduced in `setUp`, and the session-start test name flows into the class and
/// method names. No lifecycle/control-plane call becomes a step or an `XCTFail`.
final class TaskListCodegenFixtureTests: XCTestCase {
    /// A UUID-backed catalog-row id with a composite accessibility label — the shape a real
    /// SwiftUI list row produces. The generator must name it from the label + role, never the UUID.
    private let rowID = "app.task_list.row.7f1c0e64-2f43-4d1e-9a1a-2c9b7e5d0a11"
    private let rowLabel = "🧺 Laundry, wash and fold the whites, Sunday"

    private func el(
        _ id: String?,
        _ label: String?,
        type: String? = nil,
        frame: RecordedRect? = nil
    ) -> RecordedElement {
        let hit = frame.map { RecordedPoint(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) }
        return RecordedElement(id: id, label: label, elementType: type, frame: frame, hitPoint: hit)
    }

    private func find(_ text: String, _ observed: [RecordedElement]) -> SessionAction {
        SessionAction(
            timestamp: Date(),
            toolName: "find_elements",
            arguments: ["contains_text": text],
            result: "Found \(observed.count) element(s)",
            isError: false,
            intent: .diagnostic,
            observedElements: observed
        )
    }

    private func step(_ tool: String, _ arguments: [String: String], intent: SessionAction.Intent = .testStep)
        -> SessionAction {
        SessionAction(
            timestamp: Date(),
            toolName: tool,
            arguments: arguments,
            result: "ok",
            isError: false,
            intent: intent
        )
    }

    /// The recorded action history exactly as the MCP recorder would persist it for this flow.
    /// A stray `compile_session_to_plan` is interleaved on purpose: an agent may run it as a
    /// mid-session preview, and the belt-and-suspenders compiler backstop must classify it
    /// `.notApplicable`, never let it reach `toolOperations` or produce a trailing `XCTFail`.
    private func recordedActions() -> [SessionAction] {
        let createButton = el("app.task_list.create_button", "New Task")
        let laundryRow = el(rowID, rowLabel, type: "cell", frame: RecordedRect(x: 16, y: 220, width: 360, height: 92))
        return [
            // --- add Laundry ---
            find("New Task", [createButton]),
            step("tap_element", ["id": "app.task_list.create_button"]),
            find("Laundry", [el(nil, "Laundry", type: "button")]),
            step("tap_element", ["label": "Laundry"]),
            find("Add", [el("checkmark", "Add", type: "button")]),
            step("tap_element", ["id": "checkmark"]),
            step("assert_visible", ["contains_text": "Laundry", "timeout_ms": "5000"], intent: .assertion),
            // --- an explicit mid-session preview; never a test step ---
            step("compile_session_to_plan", ["test_name": "Task List Round Trip"]),
            // --- delete Laundry: canonical semantic row-gesture workflow ---
            find("Laundry", [laundryRow]),
            step("swipe_in_direction", ["direction": "left", "element_id": rowID]),
            find("Delete", [el("trash", "Delete", type: "button")]),
            step("tap_element", ["id": "trash"]),
            step("assert_absent", ["contains_text": "Laundry", "timeout_ms": "5000"], intent: .assertion),
            // --- add Laundry again ---
            find("New Task", [createButton]),
            step("tap_element", ["id": "app.task_list.create_button"]),
            find("Laundry", [el(nil, "Laundry", type: "button")]),
            step("tap_element", ["label": "Laundry"]),
            find("Add", [el("checkmark", "Add", type: "button")]),
            step("tap_element", ["id": "checkmark"]),
            step("assert_visible", ["contains_text": "Laundry", "timeout_ms": "5000"], intent: .assertion)
        ]
    }

    private func recordedReport() -> SessionReport {
        let actions = recordedActions()
        return SessionReport(
            sessionID: "F1A2B3C4-0000-4000-8000-000000000001",
            appID: "com.example.tasks",
            deviceID: "simulator",
            platform: "ios",
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 1,
            actionCount: actions.count,
            errorCount: 0,
            isActive: false,
            actions: actions,
            launchEnvironment: [
                "APP_AUTOMATED_TESTING": "1",
                "APP_UI_TEST_RESET_STATE": "1"
            ],
            testName: "Task List Round Trip"
        )
    }

    private func generatedSource() throws -> String {
        let compiled = try SessionPlanCompiler.compile(
            report: recordedReport(), testName: nil, testDescription: nil
        )
        XCTAssertTrue(
            compiled.studioTest.compiledPlan?.excludedWarnings.isEmpty ?? false,
            "The self-contained Laundry flow must compile with no dropped required actions."
        )
        return try XCUITestEmitter().generate(compiled.studioTest).source
    }

    func testTaskListRoundTripCompilesToACompleteSemanticXCTest() throws {
        let source = try generatedSource()

        // Session-start test name flows into both the class and the method name.
        XCTAssertTrue(source.contains("final class TaskListRoundTripTest"))
        XCTAssertTrue(source.contains("func testTaskListRoundTrip()"))

        // Launch environment persisted and reproduced in setUp.
        XCTAssertTrue(source.contains(#"app.launchEnvironment["APP_UI_TEST_RESET_STATE"] = "1""#))

        // The catalog row: label + role, never the UUID. The UUID stays in the selector *string*
        // (the stable contract) but must never appear in a generated identifier.
        XCTAssertTrue(source.contains("let laundryTaskRow = app.descendants(matching: .any)["))
        XCTAssertTrue(source.contains("laundryTaskRow.swipeLeft()"))
        XCTAssertFalse(source.contains("app.swipeLeft()"))
        XCTAssertFalse(source.contains("let 7f1c0e64"))
        XCTAssertFalse(source.contains("7f1c0e642F43"), "a camelCased UUID fragment leaked into an identifier")
        XCTAssertNil(
            source.range(of: #"let [A-Za-z0-9]*[0-9a-fA-F]{7}"#, options: .regularExpression),
            "a hex/UUID-shaped run leaked into a generated identifier"
        )

        // The "Laundry" option on the create screen is a distinct role from the catalog row.
        XCTAssertTrue(source.contains("laundryPresetOption"))
        XCTAssertFalse(source.contains("laundry2"))

        // Icon buttons keep their own clean identifier; neighbouring text must not pull them
        // into delete2 / add2.
        XCTAssertTrue(source.contains(#"let trash = app.descendants(matching: .any)["trash"]"#))
        XCTAssertTrue(source.contains(#"let checkmark = app.descendants(matching: .any)["checkmark"]"#))
        XCTAssertFalse(source.contains("delete2"))
        XCTAssertFalse(source.contains("add2"))

        // Semantic assertions for both mutations.
        XCTAssertTrue(source.contains(#"waitForAbsence(laundry, named: "laundry""#))
        XCTAssertTrue(
            source.range(of: #"waitForHittability\(laundry, named: "laundry""#, options: .regularExpression) != nil
        )

        // No lifecycle/control-plane contamination.
        XCTAssertFalse(source.contains("XCTFail("))
        XCTAssertFalse(source.contains("compile_session_to_plan"))
        XCTAssertFalse(source.contains("end_session"))
    }

    /// `amoo generate test` refuses to emit only when `compiledPlan.excludedWarnings` is non-empty
    /// (`runGenerateTestCommand`, the `--allow-incomplete` gate). Prove this plan clears that gate.
    /// The CLI-surface equivalent runs in `GeneratePlanCommandTests.testLaundryFixtureGeneratesWithoutAllowIncomplete`.
    func testPlanClearsTheAllowIncompleteGate() throws {
        let compiled = try SessionPlanCompiler.compile(
            report: recordedReport(), testName: nil, testDescription: nil
        )
        XCTAssertTrue((compiled.studioTest.compiledPlan?.excludedWarnings ?? []).isEmpty)
        XCTAssertFalse(try XCUITestEmitter().generate(compiled.studioTest).source.contains("XCTFail("))
    }

    /// The recorder and the compiler both keep `compile_session_to_plan` out of the test: the
    /// recorder never writes it, and the compiler backstop classifies a stray one `.notApplicable`
    /// (not `.excluded`), so an explicit preview before `end_session` cannot contaminate the plan.
    func testExplicitCompilePreviewIsNeverATestStep() throws {
        XCTAssertTrue(DriverToolExecutor.controlPlaneTools.contains("compile_session_to_plan"))
        XCTAssertTrue(SessionPlanCompiler.controlPlaneTools.contains("compile_session_to_plan"))

        let compiled = try SessionPlanCompiler.compile(
            report: recordedReport(), testName: nil, testDescription: nil
        )
        let plan = compiled.studioTest.compiledPlan
        let operationTools = (plan?.toolOperations ?? []).map(\.tool)
        XCTAssertFalse(operationTools.contains("compile_session_to_plan"))
        XCTAssertFalse(operationTools.contains("end_session"))
        XCTAssertTrue(plan?.excludedWarnings.isEmpty ?? false)

        let lifecycleWarnings = (plan?.warnings ?? []).filter { $0.toolName == "compile_session_to_plan" }
        XCTAssertEqual(lifecycleWarnings.map(\.kind), [.notApplicable])
    }

    func testGeneratedNamesAreStableAcrossRepeatedCompilation() throws {
        let sources = try (0 ..< 5).map { _ in try generatedSource() }
        XCTAssertEqual(Set(sources).count, 1, "Code generation is not deterministic across runs.")
    }
}
