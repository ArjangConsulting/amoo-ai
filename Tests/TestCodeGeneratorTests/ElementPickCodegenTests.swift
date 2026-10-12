import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// `index` / `first` on a recorded step become `.element(boundBy:)` / `.firstMatch`, so a test
/// recorded against duplicate accessibility elements (iPadOS 27's doubled top tab bar) still
/// resolves to exactly one element instead of failing as ambiguous.
final class ElementPickCodegenTests: XCTestCase {
    private func source(
        _ operations: [StudioToolOperation],
        context: StudioTestContext? = nil
    ) throws -> String {
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Pick Flow",
            description: "",
            platform: .ios,
            steps: [.init(id: "step-1", instruction: "Tap", expected: "Tapped")],
            testContext: context,
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: operations)
        )
        return try XCUITestEmitter().generate(test).source
    }

    func testASwipeOnAPickedElementKeepsThePickInTheQuery() throws {
        let code = try source([
            .init(
                id: "op-1",
                tool: "swipe_in_direction",
                arguments: ["element_id": "day.screen", "first": "true", "direction": "up"]
            )
        ])
        XCTAssertTrue(
            code.contains(#"app.descendants(matching: .any).matching(identifier: "day.screen").firstMatch"#), code
        )
        XCTAssertTrue(code.contains(".swipeUp()"), code)
    }

    func testIDWithIndexNarrowsAMatchingQueryByPosition() throws {
        let code = try source([.init(id: "op-1", tool: "tap_element", arguments: ["id": "tab.reports", "index": "1"])])
        XCTAssertTrue(
            code.contains(#"app.descendants(matching: .any).matching(identifier: "tab.reports").element(boundBy: 1)"#),
            code
        )
        XCTAssertFalse(code.contains(#"app.descendants(matching: .any)["tab.reports"]"#), code)
    }

    func testIDWithFirstUsesFirstMatch() throws {
        let code = try source([.init(
            id: "op-1", tool: "tap_element", arguments: ["id": "tab.reports", "first": "true"]
        )])
        XCTAssertTrue(
            code.contains(#"app.descendants(matching: .any).matching(identifier: "tab.reports").firstMatch"#),
            code
        )
    }

    func testLabelWithIndexReplacesTheImplicitFirstMatch() throws {
        let code = try source([.init(id: "op-1", tool: "tap_element", arguments: ["label": "Reports", "index": "0"])])
        XCTAssertTrue(
            code.contains(#"NSPredicate(format: "label == %@", "Reports")).element(boundBy: 0)"#),
            code
        )
        XCTAssertFalse(code.contains("firstMatch"), code)
    }

    func testContainsTextWithIndex() throws {
        let code = try source([.init(
            id: "op-1", tool: "assert_visible", arguments: ["contains_text": "Rep", "index": "2"]
        )])
        XCTAssertTrue(code.contains(#"label CONTAINS %@", "Rep")).element(boundBy: 2)"#), code)
    }

    func testStepsWithoutAPickAreUnchanged() throws {
        let code = try source([
            .init(id: "op-1", tool: "tap_element", arguments: ["id": "plain"]),
            .init(id: "op-2", tool: "tap_element", arguments: ["label": "Plain"])
        ])
        XCTAssertTrue(code.contains(#"app.descendants(matching: .any)["plain"]"#), code)
        XCTAssertTrue(code.contains(#"NSPredicate(format: "label == %@", "Plain")).firstMatch"#), code)
    }

    func testMappedIDUsesTheContextExpressionInTheNarrowedQuery() throws {
        let context = StudioTestContext(selectorExpressions: ["tab.reports": "AppIDs.reports.tab"])
        let code = try source(
            [.init(id: "op-1", tool: "tap_element", arguments: ["id": "tab.reports", "index": "1"])],
            context: context
        )
        XCTAssertTrue(
            code.contains(
                "app.descendants(matching: .any).matching(identifier: AppIDs.reports.tab).element(boundBy: 1)"
            ),
            code
        )
    }

    func testCustomLookupTemplateCannotBeNarrowedSoItIsRejectedRatherThanIgnored() {
        let context = StudioTestContext(
            selectorExpressions: ["tab.reports": "AppIDs.reports.tab"],
            idLookupTemplate: "app.element(id: {{id}})"
        )
        XCTAssertThrowsError(try source(
            [.init(id: "op-1", tool: "tap_element", arguments: ["id": "tab.reports", "index": "1"])],
            context: context
        ))
    }

    func testInvalidIndexIsRejectedInsteadOfGuessed() {
        for bad in ["-1", "two", ""] {
            XCTAssertThrowsError(try source([.init(
                id: "op-1", tool: "tap_element", arguments: ["id": "x", "index": bad]
            )]), "index '\(bad)'") { error in
                guard case let TestCodeGeneratorError.invalidArgument(_, argument, value) = error else {
                    return XCTFail("Unexpected error \(error)")
                }
                XCTAssertEqual(argument, "index")
                XCTAssertEqual(value, bad)
            }
        }
    }
}

/// Android picks: Espresso gets a stateless `withIndex` matcher, Compose indexes `onAllNodes`.
final class AndroidElementPickCodegenTests: XCTestCase {
    private func test(_ operations: [StudioToolOperation]) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Pick Flow",
            description: "",
            platform: .android,
            steps: [.init(id: "step-1", instruction: "Tap", expected: "Tapped")],
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: operations)
        )
    }

    func testEspressoWrapsTheMatcherInWithIndexOnlyWhenPicked() throws {
        let picked = try EspressoEmitter().generate(test([
            .init(id: "1", tool: "tap_element", arguments: ["id": "tab.reports", "index": "2"]),
            .init(id: "2", tool: "tap_element", arguments: ["label": "Reports", "first": "true"])
        ])).source
        XCTAssertTrue(picked.contains(#"withIndex(anyOf(hasResourceEntryName("tab.reports")"#), picked)
        XCTAssertTrue(picked.contains(#"withContentDescription("tab.reports")), 2)"#), picked)
        XCTAssertTrue(picked.contains(#"withIndex(anyOf(withText("Reports")"#), picked)
        XCTAssertTrue(picked.contains("private fun withIndex("), picked)

        let plain = try EspressoEmitter().generate(test([
            .init(id: "1", tool: "tap_element", arguments: ["id": "tab.reports"])
        ])).source
        XCTAssertFalse(plain.contains("withIndex"), "no pick, no helper")
    }

    func testComposeIndexesAllNodesForAPick() throws {
        let code = try ComposeEspressoEmitter().generate(test([
            .init(id: "1", tool: "tap_element", arguments: ["id": "tab.reports", "index": "1"]),
            .init(id: "2", tool: "tap_element", arguments: ["id": "tab.reports", "first": "true"]),
            .init(id: "3", tool: "tap_element", arguments: ["id": "plain"])
        ])).source
        XCTAssertTrue(code.contains(#"composeTestRule.onAllNodes(hasTestTag("tab.reports"))[1]"#), code)
        XCTAssertTrue(code.contains(#"composeTestRule.onAllNodes(hasTestTag("tab.reports"))[0]"#), code)
        XCTAssertTrue(code.contains(#"composeTestRule.onNode(hasTestTag("plain"))"#), code)
    }
}

final class RepeatedWaitCollapseTests: XCTestCase {
    func testAnAssertThenATapOfTheSameElementWaitsOnce() {
        let body = """
                let close = app.buttons["Close"]
                waitForHittability(close, named: "close", timeout: 5.0)

                waitForHittability(close, named: "close", timeout: 5.0)
                close.tap()
        """
        let collapsed = XCUITestEmitter.collapsingRepeatedWaits(body)
        XCTAssertEqual(collapsed.components(separatedBy: "waitForHittability(").count - 1, 1, collapsed)
        XCTAssertFalse(collapsed.contains("\n\n"), collapsed)
        XCTAssertTrue(collapsed.hasSuffix("close.tap()"))
    }

    func testDifferentOrNonAdjacentWaitsAreKept() {
        let body = """
                waitForHittability(a, named: "a", timeout: 5.0)
                waitForHittability(b, named: "b", timeout: 5.0)
                a.tap()
                waitForHittability(a, named: "a", timeout: 5.0)
        """
        XCTAssertEqual(XCUITestEmitter.collapsingRepeatedWaits(body), body)
    }
}
