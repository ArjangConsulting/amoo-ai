@testable import CLI
import Foundation
import StudioProtocol
import TestCodeGenerator
import TestSession
import XCTest

// Compact inline report fixtures keep each scenario's full input visible beside its expectation.
// swiftlint:disable multiline_arguments

/// `amoo generate plan` — the offline replay path for a recorded scenario. Recompiles a
/// `report.json` into `plan.json` with the same guarantees as the MCP `compile_session_to_plan`
/// tool: control-plane calls dropped, element-scoped gestures keeping their row identity, and a
/// descriptive test name recovered from the recording.
final class GeneratePlanCommandTests: XCTestCase {
    private func action(
        _ tool: String,
        _ arguments: [String: String],
        intent: SessionAction.Intent = .testStep,
        isError: Bool = false,
        observed: [RecordedElement] = []
    ) -> SessionAction {
        SessionAction(
            timestamp: Date(), toolName: tool, arguments: arguments, result: "ok",
            isError: isError, intent: intent, observedElements: observed
        )
    }

    private func writeReport(_ actions: [SessionAction]) throws -> String {
        let report = SessionReport(
            sessionID: "S", appID: "com.example.app", deviceID: "device", platform: "ios",
            startedAt: Date(), endedAt: Date(), durationSeconds: 1, actionCount: actions.count,
            errorCount: actions.filter(\.isError).count, isActive: false, actions: actions,
            launchEnvironment: ["APP_SKIP_ONBOARDING": "1"]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-\(UUID().uuidString).json")
        try SessionReport.makeJSONEncoder().encode(report).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func laundryActions() -> [SessionAction] {
        let rowID = "app.task_list.row.1a4f72d9-2750-4c70-9eca-9bdef50ba34a"
        return [
            action("tap_element", ["id": "app.tab.tasks"]),
            action("find_elements", ["contains_text": "Laundry"], intent: .diagnostic, observed: [
                RecordedElement(
                    id: rowID,
                    label: "🧺 Laundry, wash and fold the whites, Sunday",
                    frame: nil,
                    hitPoint: nil
                )
            ]),
            action("swipe_in_direction", ["direction": "left", "element_id": rowID]),
            action("tap_element", ["id": "trash"]),
            action("assert_absent", ["contains_text": "Laundry"], intent: .assertion),
            action("tap_element", ["id": "app.task_list.create_button"]),
            action("tap_element", ["label": "Laundry"]),
            action("tap_element", ["label": "Add"]),
            action("assert_visible", ["contains_text": "Laundry"], intent: .assertion),
            action("compile_session_to_plan", [
                "test_name": "SkipOnboardingDeleteAndAddLaundryTask",
                "test_description": "Skip onboarding, delete Laundry, then add Laundry."
            ])
        ]
    }

    func testRecompilesReportToASemanticPlanWithoutControlPlaneSteps() throws {
        let reportPath = try writeReport(laundryActions())
        let result = try runGeneratePlanCommand(
            options: GeneratePlanOptions(
                reportPath: reportPath, outputDirectory: nil, contextPath: nil,
                testName: nil, testDescription: nil
            )
        )
        XCTAssertEqual(result.exitCode, 0)
        let plan = try JSONDecoder().decode(StudioAuthoredTest.self, from: Data(result.output.utf8))

        XCTAssertEqual(plan.name, "SkipOnboardingDeleteAndAddLaundryTask")
        let ops = try XCTUnwrap(plan.compiledPlan?.toolOperations)
        XCTAssertFalse(ops.contains { $0.tool == "compile_session_to_plan" })
        XCTAssertTrue(plan.compiledPlan?.excludedWarnings.isEmpty ?? false)

        let swipe = try XCTUnwrap(ops.first { $0.tool == "swipe_in_direction" })
        XCTAssertEqual(swipe.arguments["element_label"], "🧺 Laundry, wash and fold the whites, Sunday")
        let pickerTap = try XCTUnwrap(ops.first { $0.tool == "tap_element" && $0.arguments["label"] == "Laundry" })
        XCTAssertEqual(pickerTap.arguments["name_hint"], "Laundry preset option")
    }

    func testFoldsAContextFileIntoTheRecompiledPlan() throws {
        let reportPath = try writeReport(laundryActions())
        let contextURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-\(UUID().uuidString).json")
        try Data(#"{"baseClass":"AppUITestCase","appFactory":"makeApp()","harnessLaunchesApp":true}"#.utf8)
            .write(to: contextURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: contextURL) }

        let result = try runGeneratePlanCommand(
            options: GeneratePlanOptions(
                reportPath: reportPath, outputDirectory: nil, contextPath: contextURL.path,
                testName: nil, testDescription: nil
            )
        )
        let plan = try JSONDecoder().decode(StudioAuthoredTest.self, from: Data(result.output.utf8))
        XCTAssertEqual(plan.testContext?.baseClass, "AppUITestCase")
        XCTAssertEqual(plan.testContext?.harnessLaunchesApp, true)
    }

    /// The self-contained Laundry round trip (add -> visible -> delete -> absent -> add -> visible)
    /// expressed purely as MCP tool calls, driven through the CLI surface: `amoo generate plan`
    /// then `amoo generate test` with **no** `--allow-incomplete`. Nothing here depends on a
    /// host app's seeded state.
    private func selfContainedLaundryActions() -> [SessionAction] {
        let rowID = "app.task_list.row.7f1c0e64-2f43-4d1e-9a1a-2c9b7e5d0a11"
        let rowLabel = "🧺 Laundry, wash and fold the whites, Sunday"
        return [
            action("find_elements", ["contains_text": "New Task"], intent: .diagnostic, observed: [
                RecordedElement(id: "app.task_list.create_button", label: "New Task", frame: nil, hitPoint: nil)
            ]),
            action("tap_element", ["id": "app.task_list.create_button"]),
            action("tap_element", ["label": "Laundry"]),
            action("tap_element", ["id": "checkmark"]),
            action("assert_visible", ["contains_text": "Laundry"], intent: .assertion),
            action("find_elements", ["contains_text": "Laundry"], intent: .diagnostic, observed: [
                RecordedElement(id: rowID, label: rowLabel, frame: nil, hitPoint: nil)
            ]),
            action("swipe_in_direction", ["direction": "left", "element_id": rowID]),
            action("tap_element", ["id": "trash"]),
            action("assert_absent", ["contains_text": "Laundry"], intent: .assertion),
            action("tap_element", ["id": "app.task_list.create_button"]),
            action("tap_element", ["label": "Laundry"]),
            action("tap_element", ["id": "checkmark"]),
            action("assert_visible", ["contains_text": "Laundry"], intent: .assertion)
        ]
    }

    func testLaundryFixtureGeneratesWithoutAllowIncomplete() throws {
        let reportPath = try writeReport(selfContainedLaundryActions())
        let planResult = try runGeneratePlanCommand(options: GeneratePlanOptions(
            reportPath: reportPath, outputDirectory: nil, contextPath: nil,
            testName: "Task List Round Trip", testDescription: nil
        ))
        XCTAssertEqual(planResult.exitCode, 0)

        let planURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("laundry-cli-plan-\(UUID().uuidString).json")
        try Data(planResult.output.utf8).write(to: planURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: planURL) }

        let emitters = StudioCodeEmitters(ios: XCUITestEmitter(), android: EspressoEmitter())
        let generated = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: planURL.path, outputDirectory: nil, allowIncomplete: false),
            emitters: emitters
        )

        XCTAssertEqual(generated.exitCode, 0, generated.output)
        XCTAssertTrue(generated.output.contains("func testTaskListRoundTrip()"))
        XCTAssertTrue(generated.output.contains("laundryTaskRow.swipeLeft()"))
        XCTAssertTrue(generated.output.contains("laundryPresetOption"))
        XCTAssertFalse(generated.output.contains("laundry2"))
        XCTAssertTrue(generated.output.contains(#"waitForAbsence(laundry, named: "laundry""#))
        XCTAssertFalse(generated.output.contains("XCTFail("))
    }

    func testParsesFlagsAndRequiresReport() {
        XCTAssertThrowsError(try parseGeneratePlanOptions(args: ["--out", "/tmp/x"]))
        XCTAssertEqual(
            try? parseGeneratePlanOptions(args: ["--report", "r.json", "--test-name", "T"]),
            GeneratePlanOptions(
                reportPath: "r.json", outputDirectory: nil, contextPath: nil,
                testName: "T", testDescription: nil
            )
        )
    }
}

// swiftlint:enable multiline_arguments
