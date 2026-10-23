// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
@testable import MCPServer
import XCTest

final class KeyboardDismissalToolTests: XCTestCase {
    private actor KeyboardDriver: PlatformDriver {
        private let controls: [ElementInfo]
        private let hidesOnTap: Bool
        private var visible: Bool
        private(set) var steps: [String] = []
        private(set) var taps: [Point] = []
        private(set) var queryCount = 0

        init(controls: [ElementInfo] = [], visible: Bool = true, hidesOnTap: Bool = true) {
            self.controls = controls
            self.visible = visible
            self.hidesOnTap = hidesOnTap
        }

        func isKeyboardVisible() async throws -> Bool {
            visible
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            queryCount += 1
            return controls.filter { $0.label == selector.label }
        }

        func pressKey(_ key: KeyboardKey, modifiers _: Set<KeyModifier>) async throws {
            steps.append(key.name)
            visible = false
        }

        func tap(at point: Point) async throws {
            steps.append("tap")
            taps.append(point)
            if hidesOnTap {
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
            visible = false
        }
    }

    private func button(_ label: String, id: String = "keyboard-dismiss") -> ElementInfo {
        ElementInfo(
            id: id, label: label, type: .button,
            frame: Rect(x: 300, y: 500, width: 60, height: 40)
        )
    }

    func testHiddenKeyboardDoesNotQueryOrAct() async {
        let driver = KeyboardDriver(visible: false)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertFalse(result.isError, result.content)
        let steps = await driver.steps
        let queryCount = await driver.queryCount
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(queryCount, 0)
    }

    func testDedicatedDismissalButtonsHideKeyboardWithoutKeysOrSwipes() async {
        for label in ["Hide keyboard", "Dismiss keyboard"] {
            let driver = KeyboardDriver(controls: [button(label), button("Done", id: "save-form")])
            let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
            XCTAssertFalse(result.isError, result.content)
            XCTAssertTrue(result.content.contains("'\(label)' button"), result.content)
            let steps = await driver.steps
            let taps = await driver.taps
            XCTAssertEqual(steps, ["tap"])
            XCTAssertEqual(taps, [Point(x: 330, y: 520)])
        }
    }

    func testAppDoneButtonCannotSaveFormAsKeyboardDismissal() async {
        let driver = KeyboardDriver(controls: [button("Done", id: "save-form")])
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertTrue(result.isError, result.content)
        XCTAssertTrue(result.content.contains("No action was taken"), result.content)
        XCTAssertTrue(result.content.contains("tap_element"), result.content)
        let steps = await driver.steps
        let visible = try? await driver.isKeyboardVisible()
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(visible, true)
    }

    func testMissingDismissalControlCannotSubmitOrSwipeAwaySheet() async {
        let driver = KeyboardDriver()
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertTrue(result.isError, result.content)
        let steps = await driver.steps
        XCTAssertTrue(steps.isEmpty)
    }

    func testMultipleDismissalControlsAreRejectedWithoutActing() async {
        for controls in [
            [button("Hide keyboard"), button("Hide keyboard", id: "second-hide")],
            [button("Hide keyboard"), button("Dismiss keyboard", id: "second-dismiss")]
        ] {
            let driver = KeyboardDriver(controls: controls)
            let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
            XCTAssertTrue(result.isError, result.content)
            let steps = await driver.steps
            XCTAssertTrue(steps.isEmpty)
        }
    }

    func testUnusableDismissalControlsAreRejectedWithoutActing() async {
        var hidden = button("Hide keyboard")
        hidden.isVisible = false
        var disabled = button("Hide keyboard")
        disabled.isEnabled = false
        var text = button("Hide keyboard")
        text.type = .staticText
        var unpositioned = button("Hide keyboard")
        unpositioned.frame = nil
        for control in [hidden, disabled, text, unpositioned] {
            let driver = KeyboardDriver(controls: [control])
            let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
            XCTAssertTrue(result.isError, result.content)
            let steps = await driver.steps
            XCTAssertTrue(steps.isEmpty)
        }
    }

    func testDismissalUsesReportedHitPoint() async {
        var control = button("Hide keyboard")
        control.hitPoint = Point(x: 320, y: 510)
        let driver = KeyboardDriver(controls: [control])
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, [Point(x: 320, y: 510)])
    }

    func testIneffectiveDismissalFailsWithoutFurtherActions() async {
        let driver = KeyboardDriver(controls: [button("Hide keyboard")], hidesOnTap: false)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertTrue(result.isError, result.content)
        XCTAssertTrue(result.content.contains("still visible"), result.content)
        XCTAssertTrue(result.content.contains("No further action"), result.content)
        let steps = await driver.steps
        XCTAssertEqual(steps, ["tap"])
    }
}

// swiftlint:enable multiline_arguments
