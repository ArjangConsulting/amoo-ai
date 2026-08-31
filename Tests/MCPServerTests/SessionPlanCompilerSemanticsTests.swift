import AmooCore
import Foundation
@testable import MCPServer
import StudioProtocol
import TestSession
import XCTest

// Compact inline report fixtures keep each scenario's full input visible beside its expectation.
// swiftlint:disable multiline_arguments

/// Compiler-level coverage for the three semantic fixes: control-plane calls never becoming a
/// generated step, element-scoped gestures keeping their row identity, and identically-labelled
/// elements with distinct roles getting distinct deterministic names.
final class SessionPlanCompilerSemanticsTests: XCTestCase {
    private func action(
        _ tool: String,
        _ arguments: [String: String] = [:],
        intent: SessionAction.Intent = .testStep,
        isError: Bool = false,
        observed: [RecordedElement] = []
    ) -> SessionAction {
        SessionAction(
            timestamp: Date(), toolName: tool, arguments: arguments, result: "ok",
            isError: isError, intent: intent, observedElements: observed
        )
    }

    private func report(_ actions: [SessionAction], testName: String? = nil) -> SessionReport {
        SessionReport(
            sessionID: "S", appID: "com.example.app", deviceID: "device", platform: "ios",
            startedAt: Date(), endedAt: Date(), durationSeconds: 1, actionCount: actions.count,
            errorCount: actions.filter(\.isError).count, isActive: false, actions: actions,
            launchEnvironment: ["APP_UI_TEST_SKIP_ONBOARDING": "1"], testName: testName
        )
    }

    private func operations(_ result: CompileSessionToPlanResult) -> [StudioToolOperation] {
        result.studioTest.compiledPlan?.toolOperations ?? []
    }

    // MARK: - Part 3: control-plane calls

    func testRecordedCompileSessionToPlanIsNotApplicableNotExcluded() throws {
        let result = try SessionPlanCompiler.compile(
            report: report([
                action("tap_element", ["id": "app.tab.home"]),
                action("assert_visible", ["contains_text": "Home"], intent: .assertion),
                action("compile_session_to_plan", ["test_name": "HomeFlow", "test_description": "Open home."])
            ]),
            testName: nil, testDescription: nil
        )

        // The control-plane call is noted, never dropped as an incomplete-plan gap.
        XCTAssertTrue(result.studioTest.compiledPlan?.excludedWarnings.isEmpty ?? false)
        let controlPlaneWarning = try XCTUnwrap(
            result.warnings.first { $0.toolName == "compile_session_to_plan" }
        )
        XCTAssertEqual(controlPlaneWarning.kind, .notApplicable)
        XCTAssertFalse(operations(result).contains { $0.tool == "compile_session_to_plan" })
    }

    func testTestNameAndDescriptionRecoveredFromRecordedControlPlaneCall() throws {
        let result = try SessionPlanCompiler.compile(
            report: report([
                action("tap_element", ["id": "app.tab.home"]),
                action("end_session", ["test_name": "SkipOnboardingOpenHome", "test_description": "Open home."])
            ]),
            testName: nil, testDescription: nil
        )
        XCTAssertEqual(result.studioTest.name, "SkipOnboardingOpenHome")
        XCTAssertEqual(result.studioTest.description, "Open home.")
    }

    func testExplicitTestNameStillWinsOverRecoveredOne() throws {
        let result = try SessionPlanCompiler.compile(
            report: report([
                action("tap_element", ["id": "app.tab.home"]),
                action("compile_session_to_plan", ["test_name": "Recovered"])
            ]),
            testName: "ExplicitName", testDescription: nil
        )
        XCTAssertEqual(result.studioTest.name, "ExplicitName")
    }

    // MARK: - Part 2: element-scoped swipe keeps row identity

    func testElementScopedSwipeGetsLabelFromPriorFindElements() throws {
        let rowID = "app.habit_catalog.row.1a4f72d9-2750-4c70-9eca-9bdef50ba34a"
        let result = try SessionPlanCompiler.compile(
            report: report([
                action("find_elements", ["contains_text": "Water"], intent: .diagnostic, observed: [
                    RecordedElement(
                        id: rowID,
                        label: "💧 Water, Track total water intake., Unit",
                        frame: nil,
                        hitPoint: nil
                    )
                ]),
                action("swipe_in_direction", ["direction": "left", "element_id": rowID]),
                action("tap_element", ["id": "trash"])
            ]),
            testName: nil, testDescription: nil
        )
        let swipe = try XCTUnwrap(operations(result).first { $0.tool == "swipe_in_direction" })
        XCTAssertEqual(swipe.arguments["element_id"], rowID, "the id stays the selector")
        XCTAssertEqual(swipe.arguments["element_label"], "💧 Water, Track total water intake., Unit")
    }

    // MARK: - Part 2: same label, different roles

    /// Same label on different screens: a catalog row (id path carries `row`) vs. a bare-label
    /// option tapped on the create screen. They must not collapse to `water` / `water2`.
    func testSameLabelRowVersusPickerOptionGetDistinctNames() throws {
        let rowID = "app.habit_catalog.row.1a4f72d9-2750-4c70-9eca-9bdef50ba34a"
        let result = try SessionPlanCompiler.compile(
            report: report([
                action("find_elements", ["contains_text": "Water"], intent: .diagnostic, observed: [
                    RecordedElement(id: rowID, label: "💧 Water", frame: nil, hitPoint: nil)
                ]),
                action("swipe_in_direction", ["direction": "left", "element_id": rowID]),
                action("tap_element", ["id": "trash"]),
                action("assert_absent", ["contains_text": "Water"], intent: .assertion),
                action("tap_element", ["id": "app.habit_catalog.create_button"]),
                action("tap_element", ["label": "Water"]),
                action("tap_element", ["label": "Add"]),
                action("assert_visible", ["contains_text": "Water"], intent: .assertion)
            ]),
            testName: nil, testDescription: nil
        )
        let ops = operations(result)
        let pickerTap = try XCTUnwrap(ops.first { $0.tool == "tap_element" && $0.arguments["label"] == "Water" })
        XCTAssertEqual(pickerTap.arguments["name_hint"], "Water preset option")
        // The row swipe keeps its row-shaped identity separately.
        let swipe = try XCTUnwrap(ops.first { $0.tool == "swipe_in_direction" })
        XCTAssertEqual(swipe.arguments["element_label"], "💧 Water")
    }

    /// Same label in the same collection with no derivable role distinction: two bare-label taps,
    /// no create → confirm shape around them. Neither is annotated — the emitter's deterministic
    /// numeric suffix is the correct answer here.
    func testSameLabelSameCollectionIsNotGivenAPresetRole() throws {
        let result = try SessionPlanCompiler.compile(
            report: report([
                action("tap_element", ["label": "Water"]),
                action("tap_element", ["label": "Water"])
            ]),
            testName: nil, testDescription: nil
        )
        XCTAssertTrue(operations(result).allSatisfy { $0.arguments["name_hint"] == nil })
    }

    func testPresetOptionAnnotationHandlesEmojiAndLocalizedLabels() throws {
        let result = try SessionPlanCompiler.compile(
            report: report([
                action("tap_element", ["id": "app.list.new_button"]),
                action("tap_element", ["label": "☕️ Café"]),
                action("tap_element", ["label": "Add"])
            ]),
            testName: nil, testDescription: nil
        )
        let optionTap = try XCTUnwrap(
            operations(result).first { $0.tool == "tap_element" && $0.arguments["label"] == "☕️ Café" }
        )
        XCTAssertEqual(optionTap.arguments["name_hint"], "☕️ Café preset option")
    }

    func testCompilationIsDeterministicForTheSameReport() throws {
        let actions: [SessionAction] = [
            action("find_elements", ["contains_text": "Water"], intent: .diagnostic, observed: [
                RecordedElement(id: "app.habit_catalog.row.uuid", label: "💧 Water", frame: nil, hitPoint: nil)
            ]),
            action("swipe_in_direction", ["direction": "left", "element_id": "app.habit_catalog.row.uuid"]),
            action("tap_element", ["id": "app.habit_catalog.create_button"]),
            action("tap_element", ["label": "Water"]),
            action("tap_element", ["label": "Add"])
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try (0 ..< 8).map { _ -> Data in
            let result = try SessionPlanCompiler.compile(
                report: report(actions), testName: nil, testDescription: nil
            )
            return try encoder.encode(result.studioTest.compiledPlan)
        }
        XCTAssertEqual(Set(encoded).count, 1)
    }
}

// swiftlint:enable multiline_arguments
