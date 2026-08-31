import Foundation
@testable import MCPServer
import StudioProtocol
import TestCodeGenerator
import TestSession
import XCTest

/// End-to-end guard for the "Skip onboarding, open Tasks, delete Groceries, add Groceries,
/// generate XCTest" acceptance scenario. Compiles a recorded session the way
/// `compile_session_to_plan` does, then generates an XCUITest, and asserts the properties the
/// agent guidance promises: deterministic launch setup, a semantic element-scoped swipe named from
/// the row's label (never its UUID), and explicit delete / add assertions.
final class IOSSessionCodegenRegressionTests: XCTestCase {
    private let rowID = "app.task_list.row.a40fb286-e7ca-42ad-9163-5a316ba856bd"
    private let compositeLabel = "🧾 Groceries, three items to buy this week, Aisle 5"

    /// `attachObservedLabel` matches by id only, so most observations need no geometry; the swipe
    /// target ("Groceries" row) gets a real frame so `resolveTarget` can bind the coordinate swipe.
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

    private func step(_ tool: String, _ arguments: [String: String]) -> SessionAction {
        SessionAction(
            timestamp: Date(), toolName: tool, arguments: arguments, result: "ok", isError: false
        )
    }

    private func recordedActions() -> [SessionAction] {
        let groceriesRow = el(rowID, compositeLabel, frame: RecordedRect(x: 16, y: 210, width: 370, height: 94))
        return [
            find("Tasks", [el("app.tab.tasks", "Tasks")]),
            step("tap_element", ["id": "app.tab.tasks"]),
            find("Groceries", [groceriesRow, el(nil, "🧾 Groceries")]),
            // The raw point swipe the agent issued after find_elements — inside the row's frame.
            step("swipe", ["from_x": "201", "from_y": "257", "to_x": "20", "to_y": "257", "duration_ms": "400"]),
            find("Delete", [el("trash", "Delete", type: "button")]),
            step("tap_element", ["id": "trash"]),
            step("assert_absent", ["contains_text": "Groceries", "timeout_ms": "5000"]),
            find("New Task", [el("app.task_list.create_button", "New Task")]),
            step("tap_element", ["id": "app.task_list.create_button"]),
            find("Groceries", [el(nil, "Groceries")]),
            step("tap_element", ["label": "Groceries"]),
            find("Add", [el("checkmark", "Add")]),
            step("tap_element", ["id": "checkmark"]),
            step("assert_visible", ["contains_text": "Groceries", "timeout_ms": "5000"])
        ]
    }

    private func recordedFlow() -> SessionReport {
        let actions = recordedActions()
        return SessionReport(
            sessionID: "00000000-0000-4000-8000-000000000000",
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
                "APP_UI_TEST_SKIP_ONBOARDING": "1",
                "APP_UI_TEST_RESET_STATE": "1"
            ],
            testName: "Skip Onboarding Delete and Add Task"
        )
    }

    private func assertAcceptanceCriteria(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        // Descriptive test name from the requested flow.
        XCTAssertTrue(source.contains("func testSkipOnboardingDeleteAndAddTask()"), file: file, line: line)
        // Deterministic launch setup.
        XCTAssertTrue(
            source.contains(#"app.launchEnvironment["APP_UI_TEST_SKIP_ONBOARDING"] = "1""#),
            file: file,
            line: line
        )
        XCTAssertTrue(
            source.contains(#"app.launchEnvironment["APP_UI_TEST_RESET_STATE"] = "1""#),
            file: file,
            line: line
        )
        // Semantic element resolution before the swipe → an element-scoped gesture,
        // named from the row's label, not its UUID.
        XCTAssertTrue(
            source.contains("let groceriesTaskRow = app.descendants(matching: .any)["),
            file: file,
            line: line
        )
        XCTAssertTrue(source.contains("groceriesTaskRow.swipeLeft()"), file: file, line: line)
        XCTAssertFalse(source.contains("app.swipeLeft()"), file: file, line: line)
        XCTAssertFalse(source.contains("a40fb286E7ca"), file: file, line: line)
        XCTAssertFalse(source.contains("let a40fb286"), file: file, line: line)
        // Icon buttons keep their own clean identifier — the neighbouring "Delete"/"Add" text
        // must not pull them into `delete2` / `add2`.
        XCTAssertTrue(source.contains(#"let trash = app.descendants(matching: .any)["trash"]"#), file: file, line: line)
        XCTAssertTrue(
            source.contains(#"let checkmark = app.descendants(matching: .any)["checkmark"]"#),
            file: file,
            line: line
        )
        XCTAssertFalse(source.contains("delete2"), file: file, line: line)
        XCTAssertFalse(source.contains("add2"), file: file, line: line)
        // Two identically-labelled elements with different roles: the catalog row vs. the option
        // tapped on the create screen. Neither may degrade to `groceries` / `groceries2`.
        XCTAssertTrue(source.contains("groceriesPresetOption"), file: file, line: line)
        XCTAssertFalse(source.contains("groceries2"), file: file, line: line)
        // Delete assertion + add assertion.
        XCTAssertTrue(source.contains(#"waitForAbsence(groceries, named: "groceries""#), file: file, line: line)
        XCTAssertTrue(
            source
                .range(of: #"waitForHittability\(groceries, named: "groceries""#, options: .regularExpression) != nil,
            file: file,
            line: line
        )
        // A complete plan generates no failure markers.
        XCTAssertFalse(source.contains("XCTFail("), file: file, line: line)
    }

    func testRecordedFlowCompilesToACompleteSemanticXCTest() throws {
        let compiled = try SessionPlanCompiler.compile(report: recordedFlow(), testName: nil, testDescription: nil)
        XCTAssertTrue(
            compiled.studioTest.compiledPlan?.excludedWarnings.isEmpty ?? false,
            "The recorded flow must compile with no dropped required actions."
        )
        let source = try XCUITestEmitter().generate(compiled.studioTest).source
        assertAcceptanceCriteria(source)
    }

    /// The MCP `initialize` instructions promise that `find_elements` + a coordinate gesture yields
    /// an element-scoped `groceriesTaskRow.swipeLeft()`. Prove the generator actually emits that
    /// identifier for the documented input, so the example can't rot.
    func testMCPInstructionsElementScopedSwipeExampleMatchesGeneratorOutput() throws {
        XCTAssertTrue(MCPStdioServer.instructions.contains("groceriesTaskRow.swipeLeft()"))

        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Delete Groceries",
            description: "",
            platform: .ios,
            steps: [.init(id: "s", instruction: "swipe", expected: "row swipes")],
            compiledPlan: .init(compiler: "t", compilerVersion: "1", toolOperations: [.init(
                id: "s",
                tool: "swipe_in_direction",
                arguments: [
                    "direction": "left",
                    "element_id": rowID,
                    "element_label": compositeLabel
                ]
            )])
        )
        let source = try XCUITestEmitter().generate(test).source
        XCTAssertTrue(source.contains("groceriesTaskRow.swipeLeft()"))
        XCTAssertFalse(source.contains("a40fb286E7ca"))
    }

    /// The canonical row-swipe workflow: `find_elements` then `swipe_in_direction` with the row's
    /// `element_id` (no coordinate fallback). The recorder stores it id-only; the compiler must
    /// still recover the row label from the prior observation so the gesture is named
    /// `groceriesTaskRow`, not `taskListRow`.
    func testElementScopedSwipeRecordingKeepsRowIdentity() throws {
        let groceriesRow = el(rowID, compositeLabel, frame: RecordedRect(x: 16, y: 210, width: 370, height: 94))
        let actions: [SessionAction] = [
            find("Tasks", [el("app.tab.tasks", "Tasks")]),
            step("tap_element", ["id": "app.tab.tasks"]),
            find("Groceries", [groceriesRow]),
            step("swipe_in_direction", ["direction": "left", "element_id": rowID]),
            find("Delete", [el("trash", "Delete", type: "button")]),
            step("tap_element", ["id": "trash"]),
            step("assert_absent", ["contains_text": "Groceries"])
        ]
        let report = SessionReport(
            sessionID: "s",
            appID: "com.example.tasks",
            deviceID: "sim",
            platform: "ios",
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 1,
            actionCount: actions.count,
            errorCount: 0,
            isActive: false,
            actions: actions
        )
        let compiled = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let source = try XCUITestEmitter().generate(compiled.studioTest).source
        XCTAssertTrue(source.contains("groceriesTaskRow.swipeLeft()"))
        XCTAssertFalse(source.contains("taskListRow"))
        // The UUID stays in the selector string (the stable contract) but never in an identifier.
        XCTAssertFalse(source.contains("let a40fb286"))
        XCTAssertFalse(source.contains("a40fb286E7ca"))
    }

    func testGeneratedNamesAreStableAcrossRepeatedCompilation() throws {
        let sources = try (0 ..< 5).map { _ -> String in
            let compiled = try SessionPlanCompiler.compile(
                report: recordedFlow(), testName: nil, testDescription: nil
            )
            return try XCUITestEmitter().generate(compiled.studioTest).source
        }
        XCTAssertEqual(Set(sources).count, 1, "Code generation is not deterministic across runs.")
    }
}
