// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP
@testable import MCPServer
import XCTest

/// `tap_element` used to answer "Tapped verified element" for taps that hit a keypad key, landed
/// outside the visible tab pill, or opened another app. These pin the refusals and the warnings.
final class TapChecksTests: XCTestCase {
    private static let window = Rect(x: 0, y: 0, width: 390, height: 844)
    private static let addButton = ElementInfo(
        id: "add", label: "Add entry", type: .button, frame: Rect(x: 20, y: 700, width: 120, height: 44)
    )

    private func screen(overlay: ViewNode? = nil) -> ViewNode {
        let target = ViewNode(id: "add", label: "Add entry", type: .button, frame: Self.addButton.frame)
        return ViewNode(
            id: "root", type: .other, frame: Self.window,
            children: [target] + (overlay.map { [$0] } ?? [])
        )
    }

    private let keypad = ViewNode(
        id: "keypad", type: .other, frame: Rect(x: 0, y: 600, width: 390, height: 244),
        children: [ViewNode(id: "key.7", label: "7", type: .button, frame: Rect(x: 10, y: 690, width: 120, height: 60))]
    )

    // MARK: - hittability

    func testControlPaintedOverTheTapPointBlocksIt() {
        let block = TapHittability.block(for: Self.addButton, at: Point(x: 80, y: 722), in: screen(overlay: keypad))
        XCTAssertEqual(block, .covered(by: "button 'key.7'"))
    }

    func testTransparentContainerOverTheTargetIsNotABlocker() {
        let veil = ViewNode(id: "veil", type: .other, frame: Self.window)
        XCTAssertNil(TapHittability.block(for: Self.addButton, at: Point(x: 80, y: 722), in: screen(overlay: veil)))
    }

    func testLabelInsideTheTargetDoesNotBlockItself() {
        let target = ViewNode(
            id: "add", label: "Add entry", type: .button, frame: Self.addButton.frame,
            children: [ViewNode(id: "inner", label: "Add", type: .button, frame: Self.addButton.frame)]
        )
        let root = ViewNode(id: "root", type: .other, frame: Self.window, children: [target])
        XCTAssertNil(TapHittability.block(for: Self.addButton, at: Point(x: 80, y: 722), in: root))
    }

    func testTapPointOutsideTheWindowIsOffScreen() {
        let block = TapHittability.block(for: Self.addButton, at: Point(x: 586, y: 53), in: screen())
        XCTAssertEqual(block, .offScreen(Point(x: 586, y: 53)))
    }

    // MARK: - tap_element

    func testRefusesAndDoesNotTapWhenCheckHittableFindsAnOverlay() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(overlay: keypad))
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "check_hittable": "true"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("covered by button 'key.7'"), result.content)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testChecksHittabilityByDefaultWhileTheKeyboardIsUp() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(overlay: keypad), keyboardVisible: true)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add"]
        )
        XCTAssertTrue(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testCheckHittableFalseTapsAnyway() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(overlay: keypad), keyboardVisible: true)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "check_hittable": "false"]
        )
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps.count, 1)
    }

    func testSkipsTheHierarchyReadByDefaultWithoutAKeyboard() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(overlay: keypad))
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add"]
        )
        XCTAssertFalse(result.isError, result.content)
        let reads = await driver.hierarchyReads
        XCTAssertEqual(reads, 0)
    }

    func testWarnsWhenTheForegroundAppChanges() async {
        let driver = TapCheckDriver(
            target: Self.addButton,
            hierarchy: screen(),
            foregrounds: ["com.jot", "com.apple.siri"]
        )
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Foreground app changed from com.jot to com.apple.siri"), result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["foreground_changed"]?.boolValue, true)
    }

    func testCheckEffectReportsNoObservableChange() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(), summaries: ["Home", "Home"])
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "check_effect": "true"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("No observable change"), result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["observable_change"]?.boolValue, false)
    }

    func testCheckEffectConfirmsAChangedScreen() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(), summaries: ["Home", "Day detail"])
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "check_effect": "true"]
        )
        XCTAssertFalse(result.content.contains("No observable change"), result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["observable_change"]?.boolValue, true)
    }
}

private actor TapCheckDriver: PlatformDriver {
    private let target: ElementInfo
    private let hierarchy: ViewNode
    private let keyboardVisible: Bool
    private var foregrounds: [String]
    private var summaries: [String]
    private(set) var taps: [Point] = []
    private(set) var hierarchyReads = 0

    init(
        target: ElementInfo,
        hierarchy: ViewNode,
        keyboardVisible: Bool = false,
        foregrounds: [String] = ["com.jot", "com.jot"],
        summaries: [String] = ["Home", "Home"]
    ) {
        self.target = target
        self.hierarchy = hierarchy
        self.keyboardVisible = keyboardVisible
        self.foregrounds = foregrounds
        self.summaries = summaries
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        [target]
    }

    func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        [target]
    }

    func tap(at point: Point) async throws {
        taps.append(point)
    }

    func isKeyboardVisible() async throws -> Bool {
        keyboardVisible
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        hierarchyReads += 1
        return hierarchy
    }

    func currentApp() async throws -> CurrentApp {
        let bundleID = foregrounds.count > 1 ? foregrounds.removeFirst() : (foregrounds.first ?? "com.jot")
        return CurrentApp(bundleID: bundleID, targetBundleID: "com.jot")
    }

    func getScreenContext() async throws -> ScreenContext {
        let summary = summaries.count > 1 ? summaries.removeFirst() : (summaries.first ?? "")
        return ScreenContext(summary: summary)
    }
}

// swiftlint:enable multiline_arguments
