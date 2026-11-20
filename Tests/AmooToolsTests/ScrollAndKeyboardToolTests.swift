// swiftlint:disable multiline_arguments
import AmooCore
@testable import AmooTools
import Foundation
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

    /// An iOS list that rubber-bands: the first read after any scroll catches the content mid-flight,
    /// including a scroll pushed against an end that leaves the content where it was. A control can
    /// animate its own press state on every read, as Jot's calendar-layout option did under the finger.
    private actor BouncingListDriver: PlatformDriver {
        private let rowVisibleAt: Int
        private let lastOffset: Int
        private let pulsingControl: Bool
        private(set) var scrolls: [Direction] = []
        private var offset = 0
        private var midFlightReads = 0
        private var reads = 0

        init(rowVisibleAt: Int, lastOffset: Int, pulsingControl: Bool = false) {
            self.rowVisibleAt = rowVisibleAt
            self.lastOffset = lastOffset
            self.pulsingControl = pulsingControl
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            reads += 1
            var drift = 0.0
            if midFlightReads > 0 {
                midFlightReads -= 1
                drift = 37
            }
            let top = Double(1200 - offset * 300) + drift
            var elements = (0 ..< 6).map { row in
                ElementInfo(
                    id: "row.\(row)", label: "Row \(row)", type: .cell,
                    frame: Rect(x: 0, y: top - 1000 + Double(row) * 50, width: 100, height: 40)
                )
            }
            elements.append(ElementInfo(
                id: "", label: "Health", type: .staticText,
                frame: Rect(x: 0, y: top, width: 100, height: 40),
                isVisible: offset >= rowVisibleAt
            ))
            if pulsingControl {
                let height = reads.isMultiple(of: 2) ? 102.0 : 108.0
                elements.append(ElementInfo(
                    id: "layout.vertical", label: "Vertical", type: .button,
                    frame: Rect(x: 0, y: 579 - height / 2, width: 117, height: height)
                ))
            }
            guard let text = selector.containsText else { return elements }
            return elements.filter { $0.label.contains(text) }
        }

        func scroll(direction: Direction, distance _: Double) async throws {
            scrolls.append(direction)
            midFlightReads = 1
            switch direction {
            case .up: offset = max(0, offset - 1)
            case .down: offset = min(lastOffset, offset + 1)
            default: break
            }
        }

        func getScreenContext() async throws -> ScreenContext {
            ScreenContext(summary: "offset \(offset)")
        }
    }

    func testReversesAtAnEndWhileTheListIsStillBouncing() async {
        let driver = BouncingListDriver(rowVisibleAt: 3, lastOffset: 5)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element",
            arguments: ["contains_text": "Health", "direction": "up", "max_attempts": "6"]
        )
        XCTAssertFalse(result.isError, result.content)
        let scrolls = await driver.scrolls
        XCTAssertEqual(scrolls, [.up, .down, .down, .down])
    }

    func testOneControlAnimatingItsOwnStateDoesNotHideTheEnd() async {
        let driver = BouncingListDriver(rowVisibleAt: 99, lastOffset: 5, pulsingControl: true)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element",
            arguments: ["contains_text": "Missing", "direction": "up", "max_attempts": "3"]
        )
        XCTAssertTrue(result.content.contains("up reached its end after 1, then down"), result.content)
        let scrolls = await driver.scrolls
        XCTAssertEqual(scrolls, [.up, .down, .down])
    }

    /// A 440x956 screen over 3000 points of content. The target row sits in the hierarchy at its
    /// content position whether or not it is on screen, as list rows near the viewport do.
    private actor LongListDriver: PlatformDriver {
        private let targetContentY: Double?
        private(set) var scrolls: [(Direction, Double)] = []
        private var contentOffset = 0.0

        init(targetContentY: Double?) {
            self.targetContentY = targetContentY
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            var elements = (0 ..< 5).map { row in
                ElementInfo(
                    id: "filler.\(row)", label: "Filler \(row)", type: .cell,
                    frame: Rect(x: 0, y: Double(row) * 200 - contentOffset, width: 440, height: 44)
                )
            }
            if let targetContentY {
                let y = targetContentY - contentOffset
                elements.append(ElementInfo(
                    id: "target", label: "Target", type: .cell,
                    frame: Rect(x: 0, y: y, width: 440, height: 44),
                    isVisible: y + 44 > 0 && y < 956
                ))
            }
            guard let id = selector.id else { return elements }
            return elements.filter { $0.id == id }
        }

        func scroll(direction: Direction, distance: Double) async throws {
            scrolls.append((direction, distance))
            switch direction {
            case .down: contentOffset = min(3000 - 956, contentOffset + distance)
            case .up: contentOffset = max(0, contentOffset - distance)
            default: break
            }
        }

        func screenGeometry() async throws -> ScreenSize {
            ScreenSize(widthPoints: 440, heightPoints: 956, widthPixels: 1320, heightPixels: 2868, scale: 3)
        }

        func getScreenContext() async throws -> ScreenContext {
            ScreenContext(summary: "offset \(contentOffset)")
        }
    }

    func testScrollsStraightToATargetTheHierarchyAlreadyHolds() async {
        let driver = LongListDriver(targetContentY: 1570)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "target", "direction": "up"]
        )
        XCTAssertFalse(result.isError, result.content)
        let scrolls = await driver.scrolls
        XCTAssertEqual(scrolls.map(\.0), [.down, .down], "the hierarchy said below, so up was never tried")
        XCTAssertEqual(scrolls.first?.1 ?? 0, 956 * 0.6, accuracy: 0.01, "capped at a page")
        XCTAssertEqual(scrolls.last?.1 ?? 0, 1592 - 573.6 - 478, accuracy: 0.01, "then exactly the rest")
    }

    func testPagesMostOfAScreenWhenTheTargetIsNotInTheHierarchy() async {
        let driver = LongListDriver(targetContentY: nil)
        _ = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "target", "max_attempts": "2"]
        )
        let distances = await driver.scrolls.map(\.1)
        XCTAssertEqual(distances, [956 * 0.6, 956 * 0.6])
    }

    func testAnExplicitDistanceCapsEveryScroll() async {
        let driver = LongListDriver(targetContentY: 1300)
        _ = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "target", "distance": "120", "max_attempts": "3"]
        )
        let distances = await driver.scrolls.map(\.1)
        XCTAssertEqual(distances, [120, 120, 120])
    }

    func testGiveUpSaysWhetherItEverFoundAnEnd() async {
        let driver = ScrollingDriver(scrollsNeeded: 99)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "scroll_to_element", arguments: ["id": "row", "max_attempts": "2"]
        )
        XCTAssertTrue(result.content.contains("no end was detected"), result.content)
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
