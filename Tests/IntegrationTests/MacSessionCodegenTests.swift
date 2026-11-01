import AmooCore
import Foundation
import SessionCompiler
import StudioProtocol
import TestCodeGenerator
import TestSession
import XCTest

/// A session recorded on this Mac compiles to a plan and generates an XCUITest that drives the
/// desktop with a pointer and the scroll wheel, never touch.
final class MacSessionCodegenTests: XCTestCase {
    private func step(_ tool: String, _ arguments: [String: String]) -> SessionAction {
        SessionAction(timestamp: Date(), toolName: tool, arguments: arguments, result: "ok", isError: false)
    }

    private func report(_ actions: [SessionAction]) -> SessionReport {
        SessionReport(
            sessionID: "00000000-0000-4000-8000-000000000001",
            appID: "com.example.notes",
            deviceID: "mac",
            platform: "macos",
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 1,
            actionCount: actions.count,
            errorCount: 0,
            isActive: false,
            actions: actions,
            testName: "Edit Note"
        )
    }

    func testMacRecordingCompilesAndGeneratesPointerInput() throws {
        let compiled = try SessionPlanCompiler.compile(
            report: report([
                step("tap_element", ["id": "new-note"]),
                step("set_text", ["id": "title", "value": "Groceries"]),
                step("scroll", ["direction": "down"]),
                step("assert_visible", ["id": "title"])
            ]),
            testName: nil,
            testDescription: nil
        )

        XCTAssertEqual(compiled.studioTest.platform, .macos)
        XCTAssertTrue(compiled.studioTest.compiledPlan?.excludedWarnings.isEmpty ?? false)
        let source = try XCUITestEmitter(target: .macos).generate(compiled.studioTest).source
        XCTAssertTrue(source.contains("func testEditNote()"), source)
        XCTAssertTrue(source.contains("newNote.click()"), source)
        XCTAssertTrue(source.contains("app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -300)"), source)
        XCTAssertFalse(source.contains(".tap()"), source)
    }

    /// A raw point `swipe` is a mouse drag on a Mac. Rewriting it as a directional swipe would
    /// replay as a wheel scroll, so it must stay excluded rather than become a different gesture.
    func testARawPointSwipeIsNotRewrittenIntoAScroll() throws {
        let row = RecordedElement(
            id: "note.row",
            label: "Groceries",
            elementType: nil,
            frame: RecordedRect(x: 0, y: 100, width: 300, height: 40),
            hitPoint: RecordedPoint(x: 150, y: 120)
        )
        let observe = SessionAction(
            timestamp: Date(),
            toolName: "find_elements",
            arguments: ["contains_text": "Groceries"],
            result: "Found 1 element(s)",
            isError: false,
            intent: .diagnostic,
            observedElements: [row]
        )
        let swipe = step("swipe", ["from_x": "250", "from_y": "120", "to_x": "20", "to_y": "120"])

        let compiled = try SessionPlanCompiler.compile(
            report: report([observe, swipe]), testName: nil, testDescription: nil
        )

        let operations: [StudioToolOperation] = compiled.studioTest.compiledPlan?.toolOperations ?? []
        let tools = operations.map(\.tool)
        XCTAssertFalse(tools.contains("swipe_in_direction"), "\(tools)")
        let excluded: [StudioPlanWarning] = compiled.studioTest.compiledPlan?.excludedWarnings ?? []
        XCTAssertEqual(excluded.map(\.toolName), ["swipe"])
    }
}
