// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP
@testable import MCPServer
@testable import SessionCompiler
import StudioProtocol
import TestSession
import XCTest

/// `assert_selected` and the selector contract it relies on: `id`, `label` and `contains_text` are
/// constraints that must all match, and selected state is only ever asserted by an explicit call.
final class AssertSelectedTests: XCTestCase {
    private static let dayID = "calendar.day.2026-10-30"
    private static let neighbourID = "calendar.day.2026-10-31"

    private func cells(selected: Bool? = false) -> [ElementInfo] {
        [
            ElementInfo(
                id: Self.dayID, label: "Friday, October 30, 2026, Range start", type: .button,
                frame: Rect(x: 0, y: 100, width: 40, height: 40), isSelected: selected
            ),
            ElementInfo(
                id: Self.neighbourID, label: "Saturday, October 31, 2026", type: .button,
                frame: Rect(x: 50, y: 100, width: 40, height: 40), isSelected: selected.map { _ in false }
            )
        ]
    }

    private func run(
        _ tool: String,
        _ arguments: [String: String],
        driver: CalendarDriver
    ) async -> ToolResult {
        await DriverToolExecutor(driver: driver).execute(
            toolName: tool, arguments: arguments.merging(["timeout_ms": "50"]) { current, _ in current }
        )
    }

    private func fields(_ result: ToolResult) -> [String: Value] {
        result.structuredContent?.objectValue ?? [:]
    }

    // MARK: - States

    func testSelectedTrueSucceedsOnASelectedElement() async {
        let driver = CalendarDriver(cells(selected: true))
        let result = await run("assert_selected", ["id": Self.dayID, "expected": "true"], driver: driver)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(fields(result)["observed"], .string("selected"))
    }

    func testSelectedFalseSucceedsOnAnExistingUnselectedElement() async {
        let driver = CalendarDriver(cells(selected: false))
        let result = await run("assert_selected", ["id": Self.dayID, "expected": "false"], driver: driver)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(fields(result)["observed"], .string("unselected"))
    }

    func testExpectedDefaultsToTrue() async {
        let selected = await run("assert_selected", ["id": Self.dayID], driver: CalendarDriver(cells(selected: true)))
        let unselected = await run(
            "assert_selected",
            ["id": Self.dayID],
            driver: CalendarDriver(cells(selected: false))
        )
        XCTAssertFalse(selected.isError, selected.content)
        XCTAssertTrue(unselected.isError)
    }

    func testTheWrongStateFailsForBothExpectationsAndNamesWhatWasChecked() async {
        let unselected = await run(
            "assert_selected", ["id": Self.dayID, "expected": "true"], driver: CalendarDriver(cells(selected: false))
        )
        let selected = await run(
            "assert_selected", ["id": Self.dayID, "expected": "false"], driver: CalendarDriver(cells(selected: true))
        )
        for (result, wanted, observed) in [(unselected, true, "unselected"), (selected, false, "selected")] {
            XCTAssertTrue(result.isError, result.content)
            let values = fields(result)
            XCTAssertEqual(values["passed"], .bool(false))
            XCTAssertEqual(values["expected"], .bool(wanted))
            XCTAssertEqual(values["observed"], .string(observed))
            XCTAssertEqual(values["resolution_failed"], .bool(false))
            XCTAssertEqual(values["selector"], .string("id=\(Self.dayID)"))
            XCTAssertTrue(result.content.contains("expected selected=\(wanted)"), result.content)
            XCTAssertTrue(result.content.contains("observed selected=\(!wanted)"), result.content)
            XCTAssertTrue(result.content.contains(Self.dayID), result.content)
        }
    }

    func testSelectedFalseDoesNotPassWhenTheElementIsAbsent() async {
        let driver = CalendarDriver(cells(selected: false))
        let result = await run(
            "assert_selected",
            ["id": "calendar.day.1999-01-01", "expected": "false"],
            driver: driver
        )
        XCTAssertTrue(result.isError, "an absent element must not satisfy a negative expectation")
        let values = fields(result)
        XCTAssertEqual(values["resolution_failed"], .bool(true))
        XCTAssertEqual(values["observed"], .string("not_found"))
        XCTAssertTrue(result.content.contains("the element must exist"), result.content)
    }

    func testPollsUntilTheStateMatches() async {
        let driver = CalendarDriver(cells(selected: false), selectAfterQueries: 3)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_selected", arguments: ["id": Self.dayID, "expected": "true", "timeout_ms": "3000"]
        )
        XCTAssertFalse(result.isError, result.content)
        let queries = await driver.queryCount
        XCTAssertGreaterThanOrEqual(queries, 3)
    }

    func testATinyTimeoutStillQueriesTheDeviceOnce() async {
        let driver = CalendarDriver(cells(selected: true))
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_selected", arguments: ["id": Self.dayID, "timeout_ms": "1"]
        )
        XCTAssertFalse(result.isError, "a 1ms deadline must not expire before the device was asked: \(result.content)")
    }

    // MARK: - Platforms that cannot report the state

    func testAPlatformWithoutSelectedStateIsRefusedNotAnsweredWithVisibility() async {
        let driver = CalendarDriver(cells(selected: nil))
        let result = await run("assert_selected", ["id": Self.dayID, "expected": "true"], driver: driver)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields(result)["code"], .string("selected_state_unsupported"))
        XCTAssertTrue(result.content.contains("unsupported"), result.content)
        // The element is visible and enabled, which is exactly why it must not be used as a stand-in.
        let visible = await run("assert_visible", ["id": Self.dayID], driver: driver)
        XCTAssertFalse(visible.isError)
    }

    // MARK: - Disambiguation and arguments

    func testDuplicateMatchesRequireDisambiguation() async {
        let twin = cells(selected: true)[0]
        let driver = CalendarDriver([twin, twin])
        let ambiguous = await run("assert_selected", ["id": Self.dayID], driver: driver)
        XCTAssertTrue(ambiguous.isError)
        XCTAssertEqual(fields(ambiguous)["code"], .string("ambiguous_selector"))

        let picked = await run("assert_selected", ["id": Self.dayID, "index": "1"], driver: driver)
        XCTAssertFalse(picked.isError, picked.content)
        let first = await run("assert_selected", ["id": Self.dayID, "first": "true"], driver: driver)
        XCTAssertFalse(first.isError, first.content)
    }

    func testAnUnrecognisedExpectationIsRejectedRatherThanGuessed() async {
        let result = await run(
            "assert_selected", ["id": Self.dayID, "expected": "maybe"], driver: CalendarDriver(cells())
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields(result)["code"], .string("invalid_argument"))
    }

    func testASelectorIsRequired() async {
        let result = await run("assert_selected", ["expected": "true"], driver: CalendarDriver(cells()))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("selector is required"), result.content)
    }

    // MARK: - Selector constraints

    func testCombinedConstraintsAreAllSentToTheDevice() async {
        let driver = CalendarDriver(cells(selected: true))
        _ = await run("assert_visible", ["id": Self.dayID, "contains_text": "Range start"], driver: driver)
        let selectors = await driver.selectors
        let selector = try? XCTUnwrap(selectors.last)
        XCTAssertEqual(selector?.id, Self.dayID)
        XCTAssertEqual(selector?.containsText, "Range start")
    }

    func testACorrectIdentifierWithIncorrectTextDoesNotPass() async {
        let driver = CalendarDriver(cells(selected: true))
        let right = await run(
            "assert_visible", ["id": Self.dayID, "contains_text": "Range start"], driver: driver
        )
        let wrong = await run(
            "assert_visible", ["id": Self.dayID, "contains_text": "Range end"], driver: driver
        )
        XCTAssertFalse(right.isError, right.content)
        XCTAssertTrue(wrong.isError, "the identifier alone must not satisfy a failing text constraint")

        for tool in ["assert_enabled", "assert_selected"] {
            let mismatched = await run(
                tool, ["id": Self.dayID, "label": "Not the label"], driver: driver
            )
            XCTAssertTrue(mismatched.isError, "\(tool) ignored a label that does not match")
        }
        let absent = await run(
            "assert_absent", ["id": Self.dayID, "contains_text": "Range end"], driver: driver
        )
        XCTAssertFalse(absent.isError, "with the text constraint applied nothing matches, so it is absent")
    }

    func testAnActionDoesNotActOnAnElementThatFailsAConstraint() async {
        let driver = CalendarDriver(cells(selected: false))
        let wrong = await run("tap_element", ["id": Self.dayID, "label": "Not the label"], driver: driver)
        XCTAssertTrue(wrong.isError)
        let tapsAfterMismatch = await driver.taps
        XCTAssertTrue(tapsAfterMismatch.isEmpty)

        let right = await run(
            "tap_element", ["id": Self.dayID, "contains_text": "Range start"], driver: driver
        )
        XCTAssertFalse(right.isError, right.content)
        let tapsAfterMatch = await driver.taps
        XCTAssertEqual(tapsAfterMatch.count, 1)
    }

    func testADescriptionIsRejectedBesideExactConstraintsInsteadOfIgnored() async {
        let driver = CalendarDriver(cells(selected: true))
        for tool in ["assert_visible", "assert_enabled", "assert_selected", "tap_element"] {
            let result = await run(tool, ["id": Self.dayID, "description": "the start date"], driver: driver)
            XCTAssertTrue(result.isError, tool)
            XCTAssertEqual(fields(result)["code"], .string("invalid_argument"), tool)
        }
    }

    // MARK: - Ancestor scope

    private func scopedCalendar() -> CalendarDriver {
        let october = ElementInfo(
            id: "calendar.day.2026-10-30", label: "Friday, October 30, 2026", type: .button,
            frame: Rect(x: 0, y: 100, width: 40, height: 40), isSelected: true
        )
        let heading = ElementInfo(
            id: "", label: "October", type: .staticText, frame: Rect(x: 0, y: 60, width: 80, height: 30)
        )
        let november = ElementInfo(
            id: "calendar.day.2026-11-05", label: "Thursday, November 5, 2026", type: .button,
            frame: Rect(x: 0, y: 400, width: 40, height: 40), isSelected: false
        )
        return CalendarDriver(
            [october, heading, november],
            parentOf: [
                "calendar.day.2026-10-30": "calendar.month.oct",
                "": "calendar.month.oct",
                "calendar.day.2026-11-05": "calendar.month.nov"
            ]
        )
    }

    func testParentIdScopesTheSearchToThatElementsDescendants() async {
        let driver = scopedCalendar()
        let inside = await run(
            "assert_selected", ["id": "calendar.day.2026-10-30", "parent_id": "calendar.month.oct"], driver: driver
        )
        XCTAssertFalse(inside.isError, inside.content)

        let outside = await run(
            "assert_selected", ["id": "calendar.day.2026-10-30", "parent_id": "calendar.month.nov"], driver: driver
        )
        XCTAssertTrue(outside.isError, "the day exists, but not under that parent")
        XCTAssertEqual(fields(outside)["resolution_failed"], .bool(true))
        XCTAssertTrue(outside.content.contains("parent_id=calendar.month.nov"), outside.content)

        for tool in ["assert_visible", "assert_enabled", "tap_element"] {
            let scoped = await run(
                tool, ["id": "calendar.day.2026-10-30", "parent_id": "calendar.month.nov"], driver: driver
            )
            XCTAssertTrue(scoped.isError, "\(tool) ignored parent_id")
        }
        let absent = await run(
            "assert_absent", ["id": "calendar.day.2026-10-30", "parent_id": "calendar.month.nov"], driver: driver
        )
        XCTAssertFalse(absent.isError, "scoped away, so nothing matches: \(absent.content)")
    }

    func testAnElementWithNoIdentifierIsScopedByItsLabel() async {
        let driver = scopedCalendar()
        let inside = await DriverToolExecutor(driver: driver).execute(
            toolName: "find_elements", arguments: ["label": "October", "parent_id": "calendar.month.oct"]
        )
        XCTAssertTrue(inside.content.contains("Found 1 element"), inside.content)
        let outside = await DriverToolExecutor(driver: driver).execute(
            toolName: "find_elements", arguments: ["label": "October", "parent_id": "calendar.month.nov"]
        )
        XCTAssertTrue(outside.content.contains("Found 0 element"), outside.content)
    }

    func testTheParentItselfIsNeverACandidateAndAMissingParentMatchesNothing() async {
        let driver = scopedCalendar()
        let itself = await run(
            "assert_visible", ["id": "calendar.month.oct", "parent_id": "calendar.month.oct"], driver: driver
        )
        XCTAssertTrue(itself.isError)
        let missing = await run(
            "assert_visible", ["id": "calendar.day.2026-10-30", "parent_id": "calendar.month.dec"], driver: driver
        )
        XCTAssertTrue(missing.isError)
    }

    func testAScopeThatCannotBeAppliedIsAnErrorNotASilentlyUnscopedQuery() async {
        let driver = CalendarDriver(cells(selected: true))
        let result = await run(
            "assert_selected", ["id": Self.dayID, "parent_id": "calendar.month"], driver: driver
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields(result)["code"], .string("scope_unavailable"))
    }

    func testFindElementsHonorsParentIdToo() async {
        let driver = scopedCalendar()
        let scoped = await DriverToolExecutor(driver: driver).execute(
            toolName: "find_elements", arguments: ["parent_id": "calendar.month.nov"]
        )
        XCTAssertFalse(scoped.isError, scoped.content)
        XCTAssertTrue(scoped.content.contains("calendar.day.2026-11-05"), scoped.content)
        XCTAssertFalse(scoped.content.contains("calendar.day.2026-10-30"), scoped.content)
    }

    // MARK: - Schema

    func testTheToolIsAdvertisedWithTheSelectorAndPickArguments() throws {
        let definitions = Dictionary(uniqueKeysWithValues: MCPServer().toolDefinitions().map { ($0.name, $0) })
        let tool = try XCTUnwrap(definitions["assert_selected"])
        for property in [
            "id",
            "label",
            "contains_text",
            "description",
            "expected",
            "timeout_ms",
            "parent_id",
            "index",
            "first",
            "session_id"
        ] {
            XCTAssertNotNil(tool.properties[property], property)
        }
        XCTAssertTrue(tool.required.isEmpty)
        XCTAssertTrue(tool.description.contains("absent element fails"))
    }
}

/// A calendar grid whose cells answer queries the way the companions do: every given selector field
/// must match, which is what makes the host's handling of combined constraints observable.
actor CalendarDriver: PlatformDriver {
    private var elements: [ElementInfo]
    private(set) var selectors: [ElementSelector] = []
    private(set) var taps: [Point] = []
    private(set) var queryCount = 0
    private let selectAfterQueries: Int?
    /// Child element id to parent id. Empty means the driver has no hierarchy to report.
    private let parentOf: [String: String]

    init(_ elements: [ElementInfo], parentOf: [String: String] = [:], selectAfterQueries: Int? = nil) {
        self.elements = elements
        self.parentOf = parentOf
        self.selectAfterQueries = selectAfterQueries
    }

    func getViewHierarchy() async throws -> ViewNode {
        guard !parentOf.isEmpty else { throw AmooError.notImplemented("getViewHierarchy") }
        var containers: [String: ViewNode] = [:]
        for parent in Set(parentOf.values) {
            containers[parent] = ViewNode(id: parent, frame: Rect(x: 0, y: 0, width: 400, height: 800))
        }
        for element in elements {
            guard let parent = parentOf[element.id] else { continue }
            // The real hierarchy names an element with no identifier by its label.
            containers[parent]?.children.append(ViewNode(
                id: element.id.isEmpty ? element.label : element.id, label: element.label, type: element.type,
                frame: element.frame
            ))
        }
        return ViewNode(id: "root", children: containers.keys.sorted().compactMap { containers[$0] })
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        try await getViewHierarchy()
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        selectors.append(selector)
        queryCount += 1
        if let selectAfterQueries, queryCount >= selectAfterQueries {
            elements = elements.map { element in
                var copy = element
                copy.isSelected = true
                return copy
            }
        }
        return elements.filter { Self.matches($0, selector) }
    }

    func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        try await findElements(selector)
    }

    /// A tap toggles the cell under the point, the way tapping a date selects and deselects it.
    func tap(at point: Point) async throws {
        taps.append(point)
        elements = elements.map { element in
            guard let frame = element.frame, element.isSelected != nil,
                  point.x >= frame.x, point.x <= frame.x + frame.width,
                  point.y >= frame.y, point.y <= frame.y + frame.height else { return element }
            var copy = element
            copy.isSelected = !(element.isSelected ?? false)
            return copy
        }
    }

    private static func matches(_ element: ElementInfo, _ selector: ElementSelector) -> Bool {
        if let id = selector.id, element.id != id {
            return false
        }
        if let label = selector.label, element.label != label {
            return false
        }
        if let text = selector.containsText, !element.label.contains(text) {
            return false
        }
        return true
    }
}

// swiftlint:enable multiline_arguments
