import Foundation
@testable import MCPServer
import StudioProtocol
import TestCodeGenerator
import TestSession
import XCTest

/// A deterministic, repository-owned end-to-end fixture for the recording -> plan -> generated-test
/// pipeline. Unlike `IOSSessionCodegenRegressionTests` (which leans on a host app's skip-onboarding
/// / reset-state launch environment already containing the habit under test), this scenario is
/// self-contained: it **adds** the row it later deletes, so it does not depend on any Sample-specific
/// seeded state.
///
/// Scenario (all steps are amoo MCP tool calls):
///
///   start clean -> add "Water" -> assert visible -> delete "Water" (find_elements ->
///   swipe_in_direction with the resolved row id -> tap Delete) -> assert absent ->
///   add "Water" again -> assert visible
///
/// Guards: no required action is dropped, `amoo generate test` succeeds **without**
/// `--allow-incomplete`, the generated XCTest carries semantic assertions for both mutations, the
/// swipe is element-scoped (`waterHabitRow.swipeLeft()`, never a UUID-derived name), the picker
/// option and the catalog row get distinct semantic names (never `water` / `water2`), the launch
/// environment is reproduced in `setUp`, and the session-start test name flows into the class and
/// method names. No lifecycle/control-plane call becomes a step or an `XCTFail`.
final class WaterHabitCodegenFixtureTests: XCTestCase {
    /// A UUID-backed catalog-row id with a composite accessibility label — the shape a real
    /// SwiftUI list row produces. The generator must name it from the label + role, never the UUID.
    private let rowID = "app.habit_catalog.row.7f1c0e64-2f43-4d1e-9a1a-2c9b7e5d0a11"
    private let rowLabel = "💧 Water, Track total water intake., Unit"

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
        let createButton = el("app.habit_catalog.create_button", "Create Habit")
        let waterRow = el(rowID, rowLabel, type: "cell", frame: RecordedRect(x: 16, y: 220, width: 360, height: 92))
        return [
            // --- add Water ---
            find("Create Habit", [createButton]),
            step("tap_element", ["id": "app.habit_catalog.create_button"]),
            find("Water", [el(nil, "Water", type: "button")]),
            step("tap_element", ["label": "Water"]),
            find("Add", [el("checkmark", "Add", type: "button")]),
            step("tap_element", ["id": "checkmark"]),
            step("assert_visible", ["contains_text": "Water", "timeout_ms": "5000"], intent: .assertion),
            // --- an explicit mid-session preview; never a test step ---
            step("compile_session_to_plan", ["test_name": "Water Habit Round Trip"]),
            // --- delete Water: canonical semantic row-gesture workflow ---
            find("Water", [waterRow]),
            step("swipe_in_direction", ["direction": "left", "element_id": rowID]),
            find("Delete", [el("trash", "Delete", type: "button")]),
            step("tap_element", ["id": "trash"]),
            step("assert_absent", ["contains_text": "Water", "timeout_ms": "5000"], intent: .assertion),
            // --- add Water again ---
            find("Create Habit", [createButton]),
            step("tap_element", ["id": "app.habit_catalog.create_button"]),
            find("Water", [el(nil, "Water", type: "button")]),
            step("tap_element", ["label": "Water"]),
            find("Add", [el("checkmark", "Add", type: "button")]),
            step("tap_element", ["id": "checkmark"]),
            step("assert_visible", ["contains_text": "Water", "timeout_ms": "5000"], intent: .assertion)
        ]
    }

    private func recordedReport() -> SessionReport {
        let actions = recordedActions()
        return SessionReport(
            sessionID: "F1A2B3C4-0000-4000-8000-000000000001",
            appID: "com.example.habits",
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
            testName: "Water Habit Round Trip"
        )
    }

    private func generatedSource() throws -> String {
        let compiled = try SessionPlanCompiler.compile(
            report: recordedReport(), testName: nil, testDescription: nil
        )
        XCTAssertTrue(
            compiled.studioTest.compiledPlan?.excludedWarnings.isEmpty ?? false,
            "The self-contained Water flow must compile with no dropped required actions."
        )
        return try XCUITestEmitter().generate(compiled.studioTest).source
    }

    func testWaterRoundTripCompilesToACompleteSemanticXCTest() throws {
        let source = try generatedSource()

        // Session-start test name flows into both the class and the method name.
        XCTAssertTrue(source.contains("final class WaterHabitRoundTripTest"))
        XCTAssertTrue(source.contains("func testWaterHabitRoundTrip()"))

        // Launch environment persisted and reproduced in setUp.
        XCTAssertTrue(source.contains(#"app.launchEnvironment["APP_UI_TEST_RESET_STATE"] = "1""#))

        // The catalog row: label + role, never the UUID. The UUID stays in the selector *string*
        // (the stable contract) but must never appear in a generated identifier.
        XCTAssertTrue(source.contains("let waterHabitRow = app.descendants(matching: .any)["))
        XCTAssertTrue(source.contains("waterHabitRow.swipeLeft()"))
        XCTAssertFalse(source.contains("app.swipeLeft()"))
        XCTAssertFalse(source.contains("let 7f1c0e64"))
        XCTAssertFalse(source.contains("7f1c0e642F43"), "a camelCased UUID fragment leaked into an identifier")
        XCTAssertNil(
            source.range(of: #"let [A-Za-z0-9]*[0-9a-fA-F]{7}"#, options: .regularExpression),
            "a hex/UUID-shaped run leaked into a generated identifier"
        )

        // The "Water" option on the create screen is a distinct role from the catalog row.
        XCTAssertTrue(source.contains("waterPresetOption"))
        XCTAssertFalse(source.contains("water2"))

        // Icon buttons keep their own clean identifier; neighbouring text must not pull them
        // into delete2 / add2.
        XCTAssertTrue(source.contains(#"let trash = app.descendants(matching: .any)["trash"]"#))
        XCTAssertTrue(source.contains(#"let checkmark = app.descendants(matching: .any)["checkmark"]"#))
        XCTAssertFalse(source.contains("delete2"))
        XCTAssertFalse(source.contains("add2"))

        // Semantic assertions for both mutations.
        XCTAssertTrue(source.contains(#"waitForAbsence(water, named: "water""#))
        XCTAssertTrue(
            source.range(of: #"waitForHittability\(water, named: "water""#, options: .regularExpression) != nil
        )

        // No lifecycle/control-plane contamination.
        XCTAssertFalse(source.contains("XCTFail("))
        XCTAssertFalse(source.contains("compile_session_to_plan"))
        XCTAssertFalse(source.contains("end_session"))
    }

    /// `amoo generate test` refuses to emit only when `compiledPlan.excludedWarnings` is non-empty
    /// (`runGenerateTestCommand`, the `--allow-incomplete` gate). Prove this plan clears that gate.
    /// The CLI-surface equivalent runs in `GeneratePlanCommandTests.testWaterFixtureGeneratesWithoutAllowIncomplete`.
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
