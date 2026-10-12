import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

// Compact inline fixtures keep each scenario's input beside its expectation.
// swiftlint:disable multiline_arguments

/// `find_elements` shows what a field currently holds, and a whole-screen listing hides the
/// elements that only repeat another one.
final class FindElementsValueAndNoiseTests: XCTestCase {
    private func run(_ elements: [ElementInfo], _ arguments: [String: String] = [:]) async -> ToolResult {
        await DriverToolExecutor(driver: DuplicateElementsDriver(elements))
            .execute(toolName: "find_elements", arguments: arguments)
    }

    // MARK: - value

    func testNonEmptyValueIsShownInTheTextAndStructuredRows() async throws {
        let field = ElementInfo(
            id: "email", label: "Email", value: "me@example.com", type: .textField,
            frame: Rect(x: 0, y: 0, width: 200, height: 40)
        )
        let result = await run([field])
        XCTAssertTrue(result.content.contains(#"[email] Email value="me@example.com""#), result.content)
        let row = try XCTUnwrap(result.structuredContent?.objectValue?["elements"]?.arrayValue?.first)
        XCTAssertEqual(row.objectValue?["value"], .string("me@example.com"))
    }

    func testEmptyAndMissingValuesAreOmitted() async throws {
        let result = await run([
            ElementInfo(id: "a", label: "A", value: "", type: .textField),
            ElementInfo(id: "b", label: "B", type: .button)
        ])
        XCTAssertFalse(result.content.contains("value="), result.content)
        let rows = try XCTUnwrap(result.structuredContent?.objectValue?["elements"]?.arrayValue)
        XCTAssertTrue(rows.allSatisfy { $0.objectValue?["value"] == nil })
    }

    func testSecureFieldsNeverShowTheirValue() async {
        let result = await run([
            ElementInfo(id: "pw", label: "Password", value: "hunter2", type: .textField, isSecureTextEntry: true)
        ])
        XCTAssertFalse(result.content.contains("hunter2"), result.content)
        XCTAssertNil(result.structuredContent?.objectValue?["elements"]?.arrayValue?.first?.objectValue?["value"])
    }

    func testValueStaysOnOneLine() async {
        let result = await run([ElementInfo(id: "n", label: "Notes", value: "a\nb \"c\"", type: .textField)])
        XCTAssertTrue(result.content.contains(#"value="a\nb \"c\"""#), result.content)
    }

    /// The session report is written to disk; typed text reaches the agent but is not persisted.
    func testRecordedResultOmitsTheValue() async {
        let result = await run([ElementInfo(id: "email", label: "Email", value: "me@example.com", type: .textField)])
        let recorded = result.recordedContent
        XCTAssertNotNil(recorded)
        XCTAssertFalse(recorded?.contains("me@example.com") ?? true, recorded ?? "")
        XCTAssertTrue(recorded?.contains("[email] Email") ?? false, recorded ?? "")
    }

    // MARK: - noise

    private static let button = ElementInfo(
        id: "tab.reports", label: "Reports", type: .button, frame: Rect(x: 0, y: 0, width: 100, height: 50)
    )
    private static let repeatedLabel = ElementInfo(
        id: "", label: "Reports", type: .staticText, frame: Rect(x: 10, y: 10, width: 60, height: 20)
    )
    private static let scrollBar = ElementInfo(
        id: "", label: "Vertical scroll bar, 1 page", type: .other, frame: Rect(x: 380, y: 0, width: 4, height: 600)
    )

    func testWholeScreenListingHidesRepeatedLabelsAndScrollBarsAndSaysSo() async {
        let result = await run([Self.button, Self.repeatedLabel, Self.scrollBar])
        XCTAssertEqual(result.structuredContent?.objectValue?["total"], .int(1))
        XCTAssertEqual(result.structuredContent?.objectValue?["hidden_noise"], .int(2))
        XCTAssertTrue(
            result.content.contains("2 noise element(s) hidden; include_noise=true lists them"),
            result.content
        )
        XCTAssertFalse(result.content.contains("scroll bar"), result.content)
    }

    func testIncludeNoiseListsEverything() async {
        let result = await run([Self.button, Self.repeatedLabel, Self.scrollBar], ["include_noise": "true"])
        XCTAssertEqual(result.structuredContent?.objectValue?["total"], .int(3))
        XCTAssertNil(result.structuredContent?.objectValue?["hidden_noise"])
    }

    /// A selector asks for specific elements, and tap_element counts matches the same way.
    func testSelectorQueriesAreNeverFiltered() async {
        let result = await run([Self.button, Self.repeatedLabel], ["label": "Reports"])
        XCTAssertEqual(result.structuredContent?.objectValue?["total"], .int(2))
    }

    /// `index` counts the device's own order, which the generated test's `boundBy:` uses.
    func testAPickIsAppliedToTheUnfilteredOrder() async {
        let result = await run([Self.button, Self.repeatedLabel], ["index": "1"])
        XCTAssertEqual(result.structuredContent?.objectValue?["total"], .int(1))
        XCTAssertTrue(result.content.contains("Found 1 element(s)"), result.content)
        XCTAssertNil(result.structuredContent?.objectValue?["hidden_noise"])
    }

    func testStaticTextWithItsOwnIdentifierOrADifferentLabelIsKept() async {
        let own = ElementInfo(
            id: "title", label: "Reports", type: .staticText, frame: Rect(x: 10, y: 10, width: 60, height: 20)
        )
        let other = ElementInfo(
            id: "", label: "Totals", type: .staticText, frame: Rect(x: 10, y: 30, width: 60, height: 10)
        )
        let outside = ElementInfo(
            id: "", label: "Reports", type: .staticText, frame: Rect(x: 500, y: 500, width: 60, height: 20)
        )
        let result = await run([Self.button, own, other, outside])
        XCTAssertEqual(result.structuredContent?.objectValue?["total"], .int(4))
    }

    func testIncludeNoiseIsAdvertised() {
        let definition = MCPServer().toolDefinitions().first { $0.name == "find_elements" }
        XCTAssertNotNil(definition?.properties["include_noise"])
    }
}

// swiftlint:enable multiline_arguments
