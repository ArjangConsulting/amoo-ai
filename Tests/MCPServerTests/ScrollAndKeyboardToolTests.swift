// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
@testable import MCPServer
import XCTest

/// `scroll_to_element` and `dismiss_keyboard` replace guesswork: a hand-tuned `scroll` distance, and
/// `press_key return`, which "succeeds" on a decimal pad without hiding anything.
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

    func testRequiresASelector() async {
        let result = await DriverToolExecutor(driver: ScrollingDriver(scrollsNeeded: 0)).execute(
            toolName: "scroll_to_element", arguments: [:]
        )
        XCTAssertTrue(result.isError)
    }

    // MARK: - dismiss_keyboard

    private actor KeyboardDriver: PlatformDriver {
        private let fix: KeyboardFix
        private var visible = true
        private(set) var steps: [String] = []

        init(fix: KeyboardFix, visible: Bool = true) {
            self.fix = fix
            self.visible = visible
        }

        func isKeyboardVisible() async throws -> Bool {
            visible
        }

        func pressKey(_: KeyboardKey, modifiers _: Set<KeyModifier>) async throws {
            steps.append("return")
            if fix == .returnKey {
                visible = false
            }
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            guard selector.label == "Done" else { return [] }
            return [ElementInfo(
                id: "done",
                label: "Done",
                type: .button,
                frame: Rect(x: 300, y: 500, width: 60, height: 40)
            )]
        }

        func tap(at _: Point) async throws {
            steps.append("tap-done")
            if fix == .doneButton {
                visible = false
            }
        }

        func swipe(
            direction _: Direction,
            distance _: Double,
            duration _: Duration,
            element _: ElementSelector?
        ) async throws {
            steps.append("swipe")
            if fix == .swipe {
                visible = false
            }
        }
    }

    func testDismissKeyboardIsANoOpWhenHidden() async {
        let driver = KeyboardDriver(fix: .nothing, visible: false)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertFalse(result.isError)
        let steps = await driver.steps
        XCTAssertTrue(steps.isEmpty)
    }

    func testDismissKeyboardStopsAtReturnWhenThatWorks() async {
        let driver = KeyboardDriver(fix: .returnKey)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertTrue(result.content.contains("Return"), result.content)
        let steps = await driver.steps
        XCTAssertEqual(steps, ["return"])
    }

    func testDismissKeyboardFallsBackToTheDoneButton() async {
        let driver = KeyboardDriver(fix: .doneButton)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertTrue(result.content.contains("'Done' button"), result.content)
        let steps = await driver.steps
        XCTAssertEqual(steps, ["return", "tap-done"])
    }

    func testDismissKeyboardFallsBackToASwipeAndThenFailsLoudly() async {
        let swipe = KeyboardDriver(fix: .swipe)
        let swiped = await DriverToolExecutor(driver: swipe).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertTrue(swiped.content.contains("swiping down"), swiped.content)

        let stuck = KeyboardDriver(fix: .nothing)
        let failed = await DriverToolExecutor(driver: stuck).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.content.contains("still visible"), failed.content)
    }
}

private enum KeyboardFix { case returnKey, doneButton, swipe, nothing }

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
