// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
@testable import MCPServer
import XCTest

/// Scrolling helpers bring elements into view without guessing a distance.
final class ScrollAndKeyboardToolTests: XCTestCase {
    private actor ScrollingDriver: PlatformDriver {
        /// Scrolls (in the requested direction) before the element becomes visible.
        private let scrollsNeeded: Int
        private let contentEndsAfter: Int?
        private(set) var scrolls: [Direction] = []
        private var offset = 0

        init(scrollsNeeded: Int, contentEndsAfter: Int? = nil) {
            self.scrollsNeeded = scrollsNeeded
            self.contentEndsAfter = contentEndsAfter
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            let visible = offset >= scrollsNeeded
            return [ElementInfo(
                id: "row", label: "Row", type: .cell,
                frame: Rect(x: 0, y: Double(900 - offset * 100), width: 100, height: 40),
                isVisible: visible
            )]
        }

        func scroll(direction: Direction, distance _: Double) async throws {
            scrolls.append(direction)
            guard direction == .down else { offset = max(0, offset - 1); return }
            if let end = contentEndsAfter, offset >= end {
                return
            }
            offset += 1
        }

        func getScreenContext() async throws -> ScreenContext {
            ScreenContext(summary: "offset \(offset)")
        }
    }

    func testScrollsDownUntilTheElementIsVisible() async {
        let driver = ScrollingDriver(scrollsNeeded: 3)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "row"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("after 3 scroll(s)"), result.content)
        let scrolls = await driver.scrolls
        XCTAssertEqual(scrolls, [.down, .down, .down])
    }

    func testAlreadyVisibleNeedsNoScroll() async {
        let driver = ScrollingDriver(scrollsNeeded: 0)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "row"]
        )
        XCTAssertFalse(result.isError)
        let scrolls = await driver.scrolls
        XCTAssertTrue(scrolls.isEmpty)
    }

    func testFailsAfterMaxAttemptsWithTheCount() async {
        let driver = ScrollingDriver(scrollsNeeded: 99)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "row", "max_attempts": "2"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("after 2 scroll(s)"), result.content)
    }

    func testReversesOnceWhenTheContentEndsAndGivesUpAtTheOtherEnd() async {
        let driver = ScrollingDriver(scrollsNeeded: 99, contentEndsAfter: 1)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "row", "max_attempts": "20"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("both ends"), result.content)
        let scrolls = await driver.scrolls
        XCTAssertTrue(scrolls.contains(.up), "it reversed after the content ended: \(scrolls)")
    }

    /// A bottom bar floats over the list: the companion calls the row visible, a tap would hit the bar.
    private actor ToolbarCoveredDriver: PlatformDriver {
        private let scrollsUntilClear: Int
        private(set) var scrolls = 0

        init(scrollsUntilClear: Int) {
            self.scrollsUntilClear = scrollsUntilClear
        }

        private var rowFrame: Rect {
            Rect(x: 0, y: scrolls >= scrollsUntilClear ? 400 : 780, width: 300, height: 44)
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            [ElementInfo(id: "row", label: "Row", type: .cell, frame: rowFrame)]
        }

        func scroll(direction _: Direction, distance _: Double) async throws {
            scrolls += 1
        }

        func getScreenContext() async throws -> ScreenContext {
            ScreenContext(summary: "scrolled \(scrolls)")
        }

        func getViewHierarchy(appID _: String?) async throws -> ViewNode {
            let row = ViewNode(id: "row", label: "Row", type: .cell, frame: rowFrame)
            let toolbar = ViewNode(
                id: "toolbar-text", label: "Text", type: .button,
                frame: Rect(x: 0, y: 760, width: 300, height: 80)
            )
            return ViewNode(
                id: "root", label: "", type: .other,
                frame: Rect(x: 0, y: 0, width: 300, height: 852),
                children: [row, toolbar]
            )
        }
    }

    func testKeepsScrollingWhileABarCoversTheVisibleElement() async {
        let driver = ToolbarCoveredDriver(scrollsUntilClear: 2)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "row"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("after 2 scroll(s)"), result.content)
    }

    func testReturnsTheCoveredElementWhenNoScrollFreesIt() async {
        let driver = ToolbarCoveredDriver(scrollsUntilClear: 99)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "row", "max_attempts": "2"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("is on screen"), result.content)
    }

    func testRequiresASelector() async {
        let result = await DriverToolExecutor(driver: ScrollingDriver(scrollsNeeded: 0)).execute(
            toolName: "scroll_to_element", arguments: [:]
        )
        XCTAssertTrue(result.isError)
    }
}

// swiftlint:enable multiline_arguments

final class GestureDistanceTests: XCTestCase {
    private actor RecordingDriver: PlatformDriver {
        private(set) var scrolls: [Double] = []
        func scroll(direction _: Direction, distance: Double) async throws {
            scrolls.append(distance)
        }

        func swipe(
            direction _: Direction,
            distance: Double,
            duration _: Duration,
            element _: ElementSelector?
        ) async throws {
            scrolls.append(distance)
        }
    }

    func testTinyDistancesAreRejectedBeforeTouchingTheDevice() async {
        for (tool, distance) in [("scroll", "0.4"), ("scroll", "1"), ("swipe_in_direction", "9.9")] {
            let driver = RecordingDriver()
            let result = await DriverToolExecutor(driver: driver).execute(
                toolName: tool, arguments: ["direction": "down", "distance": distance]
            )
            XCTAssertTrue(result.isError, "\(tool) \(distance): \(result.content)")
            XCTAssertTrue(result.content.contains("at least 10"), result.content)
            let sent = await driver.scrolls
            XCTAssertTrue(sent.isEmpty, "\(tool) \(distance) must not reach the device")
        }
    }

    func testRealDistancesAndTheDefaultStillGo() async {
        let driver = RecordingDriver()
        let executor = DriverToolExecutor(driver: driver)
        _ = await executor.execute(toolName: "scroll", arguments: ["direction": "down", "distance": "10"])
        _ = await executor.execute(toolName: "scroll", arguments: ["direction": "down"])
        _ = await executor.execute(toolName: "swipe_in_direction", arguments: ["direction": "up", "distance": "250"])
        let sent = await driver.scrolls
        XCTAssertEqual(sent, [10, 300, 250])
    }
}
