// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP
@testable import MCPServer
@testable import SessionCompiler
import TestSession
import XCTest

/// iPadOS 27's top tab bar exposes every tab twice with an identical id, label and frame, and a
/// Reports chip shares a label with its chart card. `index` / `first` let a caller say which.
final class ElementPickTests: XCTestCase {
    private static let tabFrame = Rect(x: 100, y: 20, width: 80, height: 44)
    private static let duplicates = [
        ElementInfo(id: "tab.reports", label: "Reports", type: .button, frame: tabFrame),
        ElementInfo(id: "tab.reports", label: "Reports", type: .button, frame: tabFrame),
        ElementInfo(
            id: "tab.reports", label: "Reports", type: .button, frame: Rect(x: 300, y: 500, width: 80, height: 44)
        )
    ]

    private func executor(_ driver: DuplicateElementsDriver) -> DriverToolExecutor {
        DriverToolExecutor(driver: driver)
    }

    // MARK: - tap_element

    func testTapElementIsAmbiguousWithoutAPickAndTheErrorNamesTheNewArguments() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let result = await executor(driver).execute(toolName: "tap_element", arguments: ["id": "tab.reports"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("matched 3 elements"), result.content)
        XCTAssertTrue(result.content.contains("index"), result.content)
        XCTAssertTrue(result.content.contains("first=true"), result.content)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testTapElementIndexTapsThatMatchsHitPoint() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let result = await executor(driver).execute(
            toolName: "tap_element", arguments: ["id": "tab.reports", "index": "2"]
        )
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, [Point(x: 340, y: 522)])
    }

    func testTapElementFirstTapsTheFirstMatch() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let result = await executor(driver).execute(
            toolName: "tap_element", arguments: ["id": "tab.reports", "first": "true"]
        )
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, [Point(x: 140, y: 42)])
    }

    func testSwipeInDirectionWithAPickSwipesFromThatMatch() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let result = await executor(driver).execute(
            toolName: "swipe_in_direction",
            arguments: ["element_id": "tab.reports", "index": "2", "direction": "left", "distance": "100"]
        )
        XCTAssertFalse(result.isError, result.content)
        let swipes = await driver.swipes
        XCTAssertEqual(swipes.count, 1)
        XCTAssertEqual(swipes.first?.from, Point(x: 340, y: 522))
        XCTAssertEqual(swipes.first?.to, Point(x: 240, y: 522), "left moves the finger left")
    }

    func testSwipePickNeedsAnElementToPickFrom() async {
        let result = await executor(DuplicateElementsDriver(Self.duplicates)).execute(
            toolName: "swipe_in_direction", arguments: ["first": "true", "direction": "up"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("element_id or element_label"), result.content)
    }

    func testIndexPastTheLastMatchNamesTheValidRange() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let result = await executor(driver).execute(
            toolName: "tap_element", arguments: ["id": "tab.reports", "index": "3"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("index 3 is out of range"), result.content)
        XCTAssertTrue(result.content.contains("0...2"), result.content)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testInvalidPickArgumentsAreRejected() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        for arguments in [
            ["id": "tab.reports", "index": "-1"],
            ["id": "tab.reports", "index": "one"],
            ["id": "tab.reports", "first": "maybe"],
            ["id": "tab.reports", "index": "0", "first": "true"]
        ] {
            let result = await executor(driver).execute(toolName: "tap_element", arguments: arguments)
            XCTAssertTrue(result.isError, "\(arguments)")
            XCTAssertTrue(result.content.contains("index") || result.content.contains("first"), result.content)
        }
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testUniqueSelectorsStillWorkWithAPick() async {
        let driver = DuplicateElementsDriver([Self.duplicates[0]])
        let result = await executor(driver).execute(
            toolName: "tap_element", arguments: ["id": "tab.reports", "index": "0"]
        )
        XCTAssertFalse(result.isError, result.content)
    }

    // MARK: - find_elements

    func testFindElementsIndexReturnsOnlyThatMatch() async throws {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let result = await executor(driver).execute(
            toolName: "find_elements", arguments: ["id": "tab.reports", "index": "2"]
        )
        XCTAssertFalse(result.isError, result.content)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["total"], .int(1))
        let rows = try XCTUnwrap(fields["elements"]?.arrayValue)
        XCTAssertEqual(rows.first?.objectValue?["x"], .double(340))
    }

    func testFindElementsWithoutAPickStillListsEveryDuplicate() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let result = await executor(driver).execute(toolName: "find_elements", arguments: ["id": "tab.reports"])
        XCTAssertEqual(result.structuredContent?.objectValue?["total"], .int(3))
    }

    func testFindElementsIndexPastTheEndIsEmptyNotAnError() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let result = await executor(driver).execute(
            toolName: "find_elements", arguments: ["id": "tab.reports", "index": "9"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["total"], .int(0))
    }

    // MARK: - assertions

    func testAssertionsAcceptAPickWhereTheyOtherwiseFailAsAmbiguous() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        for tool in ["assert_visible", "assert_enabled"] {
            let plain = await executor(driver).execute(
                toolName: tool, arguments: ["id": "tab.reports", "timeout_ms": "50"]
            )
            XCTAssertTrue(plain.isError, "\(tool) without a pick should be ambiguous")
            let picked = await executor(driver).execute(
                toolName: tool, arguments: ["id": "tab.reports", "index": "1", "timeout_ms": "50"]
            )
            XCTAssertFalse(picked.isError, "\(tool): \(picked.content)")
        }
    }

    func testAssertAbsentTreatsAnIndexPastTheLastMatchAsAbsent() async {
        let driver = DuplicateElementsDriver(Self.duplicates)
        let past = await executor(driver).execute(
            toolName: "assert_absent", arguments: ["id": "tab.reports", "index": "3", "timeout_ms": "50"]
        )
        XCTAssertFalse(past.isError, past.content)
        let present = await executor(driver).execute(
            toolName: "assert_absent", arguments: ["id": "tab.reports", "index": "2", "timeout_ms": "50"]
        )
        XCTAssertTrue(present.isError)
    }

    // MARK: - schema

    func testPickArgumentsAreAdvertisedOnTheSelectorToolsOnly() {
        let definitions = Dictionary(uniqueKeysWithValues: MCPServer().toolDefinitions().map { ($0.name, $0) })
        let selectorTools = [
            "find_elements", "tap_element", "assert_visible", "assert_enabled", "assert_absent", "assert_value"
        ]
        for tool in selectorTools {
            XCTAssertNotNil(definitions[tool]?.properties["index"], tool)
            XCTAssertNotNil(definitions[tool]?.properties["first"], tool)
        }
        for tool in ["set_text", "fill_field", "tap"] {
            XCTAssertNil(definitions[tool]?.properties["index"], tool)
        }
    }

    // MARK: - recording -> plan

    /// The pick has to survive into the compiled plan, or the generated test would be ambiguous again.
    func testRecordedPickReachesTheCompiledPlanOperation() throws {
        let tap = SessionAction(
            timestamp: Date(), toolName: "tap_element",
            arguments: ["id": "tab.reports", "index": "1"], result: "ok", isError: false
        )
        let report = SessionReport(
            sessionID: "s", appID: "com.example", deviceID: "d", platform: "ios",
            startedAt: Date(), endedAt: Date(), durationSeconds: 1, actionCount: 1, errorCount: 0,
            isActive: false, actions: [tap]
        )
        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let operation = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations?.first)
        XCTAssertEqual(operation.tool, "tap_element")
        XCTAssertEqual(operation.arguments["id"], "tab.reports")
        XCTAssertEqual(operation.arguments["index"], "1")
    }
}

/// Reports a fixed element list for every query and records taps.
actor DuplicateElementsDriver: PlatformDriver {
    private let elements: [ElementInfo]
    private(set) var taps: [Point] = []

    init(_ elements: [ElementInfo]) {
        self.elements = elements
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        elements
    }

    func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        elements
    }

    func tap(at point: Point) async throws {
        taps.append(point)
    }

    private(set) var swipes: [(from: Point, to: Point)] = []

    func swipe(from: Point, to: Point, duration _: Duration) async throws {
        swipes.append((from, to))
    }
}

// swiftlint:enable multiline_arguments
