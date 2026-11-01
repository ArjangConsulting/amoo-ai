import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// XCUITest generated for a macOS session: pointer and scroll-wheel input in place of touch.
final class XCUITestMacCodegenTests: XCTestCase {
    private func makeTest(
        _ operations: [StudioToolOperation],
        context: StudioTestContext? = nil
    ) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Notes Flow",
            description: "",
            platform: .macos,
            steps: [],
            testContext: context,
            compiledPlan: .init(compiler: "test", compilerVersion: "1", toolOperations: operations)
        )
    }

    private func mac(_ operations: [StudioToolOperation], context: StudioTestContext? = nil) throws -> String {
        try XCUITestEmitter(target: .macos).generate(makeTest(operations, context: context)).source
    }

    private func op(_ tool: String, _ arguments: [String: String] = [:]) -> StudioToolOperation {
        StudioToolOperation(id: tool, tool: tool, arguments: arguments)
    }

    func testTapIsAClickAndNoTouchAPIAppears() throws {
        let source = try mac([op("tap_element", ["id": "new-note"])])

        XCTAssertTrue(source.contains("newNote.click()"), source)
        XCTAssertFalse(source.contains(".tap()"), source)
        XCTAssertFalse(source.contains("swipe"), source)
        XCTAssertFalse(source.contains("pressBack"), source)
        XCTAssertFalse(source.contains("navigationBars"), source)
    }

    func testReplaceTextSelectsAllInsteadOfCountingDeletes() throws {
        let source = try mac([op("set_text", ["id": "title", "value": "Groceries"])])

        XCTAssertTrue(source.contains("element.click()"), source)
        XCTAssertTrue(source.contains(#"element.typeKey("a", modifierFlags: .command)"#), source)
        XCTAssertTrue(source.contains("element.typeKey(.delete, modifierFlags: [])"), source)
        XCTAssertFalse(source.contains("element.tap()"), source)
        XCTAssertTrue(source.contains(#"replaceText(in: title, with: "Groceries")"#), source)
    }

    func testScrollAndSwipeBecomeWheelScrollsThatMoveContentLikeTheCompanion() throws {
        let source = try mac([
            op("scroll", ["direction": "down"]),
            op("scroll", ["direction": "up", "distance": "120"]),
            op("swipe_in_direction", ["direction": "left"]),
            op("swipe_in_direction", ["direction": "up", "element_id": "list"])
        ])

        // scroll(down) is a swipe up, which the companion performs as a negative deltaY.
        XCTAssertTrue(source.contains("app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -300)"), source)
        XCTAssertTrue(source.contains("app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: 120)"), source)
        XCTAssertTrue(source.contains("app.windows.firstMatch.scroll(byDeltaX: -300, deltaY: 0)"), source)
        XCTAssertTrue(source.contains("list.scroll(byDeltaX: 0, deltaY: -300)"), source)
        XCTAssertFalse(source.contains("app.scroll("), "the app element's frame is infinite on a Mac")
    }

    func testScrollToElementScrollsTheWindowUntilHittable() throws {
        let source = try mac([op("scroll_to_element", ["id": "footer", "max_attempts": "3"])])

        XCTAssertTrue(
            source.contains(
                "for _ in 0 ..< 3 where !footer.isHittable { app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -300) }"
            ),
            source
        )
        XCTAssertTrue(source.contains("waitForHittability(footer"), source)
    }

    func testDragIsAClickAndHoldDrag() throws {
        let source = try mac([op("drag", ["id": "card", "to_id": "done", "hold_ms": "600"])])

        XCTAssertTrue(source.contains("card.click(forDuration: 0.6, thenDragTo: done)"), source)
        XCTAssertFalse(source.contains("press(forDuration"), source)
    }

    func testStepsWithNoMacEquivalentStopGenerationInsteadOfBeingDropped() {
        for tool in ["pinch", "press_back"] {
            XCTAssertThrowsError(try mac([op(tool, ["scale": "2"])]), tool) { error in
                guard case let TestCodeGeneratorError.unsupportedOnTarget(failed, target, _) = error else {
                    return XCTFail("\(error)")
                }
                XCTAssertEqual(failed, tool)
                XCTAssertEqual(target, "macOS")
            }
        }
    }

    func testAnIdiomRequirementIsRefusedBecauseAMacHasNone() {
        let context = StudioTestContext(requiredIdiom: .phone)
        XCTAssertThrowsError(try mac([op("tap_element", ["id": "a"])], context: context))
    }

    func testSharedStepsKeepTheirIOSRendering() throws {
        let source = try mac([
            op("assert_visible", ["id": "title"]),
            op("assert_value", ["id": "title", "value": "Groceries"]),
            op("type_text", ["text": "hi"]),
            op("take_screenshot")
        ])

        XCTAssertTrue(source.contains("waitForHittability(title"), source)
        XCTAssertTrue(source.contains(#"XCTAssertEqual(title.value as? String, "Groceries")"#), source)
        XCTAssertTrue(source.contains(#"app.typeText("hi")"#), source)
        XCTAssertTrue(source.contains("XCTAttachment(screenshot: app.screenshot())"), source)
    }

    func testIOSOutputIsUnchangedByTheTargetParameter() throws {
        let operations = [op("tap_element", ["id": "a"]), op("set_text", ["id": "a", "value": "x"])]
        let ios = makeTest(operations)
        XCTAssertEqual(
            try XCUITestEmitter().generate(ios).source,
            try XCUITestEmitter(target: .ios).generate(ios).source
        )
        XCTAssertTrue(try XCUITestEmitter().generate(ios).source.contains("private func pressBack()"))
    }

    func testGeneratedSourceCompilesAgainstTheMacOSSDKUnderSwift6() throws {
        let source = try mac([
            op("tap_element", ["id": "new-note"]),
            op("set_text", ["id": "title", "value": "Groceries"]),
            op("type_text", ["text": "milk"]),
            op("scroll", ["direction": "down"]),
            op("scroll_to_element", ["id": "footer"]),
            op("swipe_in_direction", ["direction": "left", "element_id": "list"]),
            op("drag", ["id": "card", "to_id": "done"]),
            op("assert_visible", ["id": "title"]),
            op("assert_selected", ["id": "title", "expected": "true"]),
            op("take_screenshot")
        ])
        try CompileVerification.verifySwiftCompiles(source, swiftVersion: 6, sdk: .macOS)
    }
}
