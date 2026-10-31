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

    private func flatAndroidScreen(rootID: String = "android-root") -> ViewNode {
        ViewNode(id: rootID, children: [
            ViewNode(id: "add", label: "Add entry", type: .staticText, frame: Self.addButton.frame),
            ViewNode(id: "", type: .button, frame: Self.addButton.frame)
        ])
    }

    func testFlatAndroidButtonOwnerDoesNotBlockItsLabel() {
        for rootID in ["android-root", "android-cli-root"] {
            XCTAssertNil(TapHittability.block(
                for: Self.addButton, at: Point(x: 80, y: 722), in: flatAndroidScreen(rootID: rootID)
            ))
        }
    }

    func testDefaultAndroidTapProceedsUncheckedAndStillChecksItsEffect() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: flatAndroidScreen())
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["hittability_checked"], .bool(false))
        XCTAssertEqual(result.structuredContent?.objectValue?["observable_change"], .bool(false))
        let taps = await driver.taps
        XCTAssertEqual(taps.count, 1)
    }

    func testRequiredAndroidHittabilityRefusesWithoutTapping() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: flatAndroidScreen())
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "check_hittable": "true"]
        )
        XCTAssertTrue(result.isError, result.content)
        XCTAssertTrue(result.content.contains("flat element list"), result.content)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testTapPointOutsideTheWindowIsOffScreen() {
        let block = TapHittability.block(for: Self.addButton, at: Point(x: 586, y: 53), in: screen())
        XCTAssertEqual(block, .offScreen(Point(x: 586, y: 53)))
    }

    // MARK: - settling

    func testSettledElementWaitsForAScrollingListToComeToRest() async throws {
        let executor = DriverToolExecutor(driver: TapCheckDriver(target: Self.addButton, hierarchy: screen()))
        var resolved = Self.addButton
        resolved.frame = Rect(x: 20, y: 500, width: 120, height: 44)
        var frames = [Rect(x: 20, y: 640, width: 120, height: 44), Self.addButton.frame, Self.addButton.frame]
            .compactMap(\.self)
        var calls = 0
        let settled = try await executor.settledElement(resolved, hierarchy: screen()) {
            calls += 1
            var next = Self.addButton
            next.frame = frames.removeFirst()
            return next
        }
        XCTAssertEqual(settled.frame, Self.addButton.frame)
        XCTAssertEqual(calls, 3)
    }

    func testSettledElementDoesNotResolveAgainOnAStillScreen() async throws {
        let executor = DriverToolExecutor(driver: TapCheckDriver(target: Self.addButton, hierarchy: screen()))
        var calls = 0
        let settled = try await executor.settledElement(Self.addButton, hierarchy: screen()) {
            calls += 1
            return Self.addButton
        }
        XCTAssertEqual(settled.frame, Self.addButton.frame)
        XCTAssertEqual(calls, 0)
    }

    func testSwipeInDirectionRejectsXAndYInsteadOfIgnoringThem() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen())
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "swipe_in_direction", arguments: ["direction": "up", "x": "100", "y": "300"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("from_x/from_y"), result.content)
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

    func testChecksHittabilityByDefaultEvenWithoutAKeyboard() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(overlay: keypad))
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add"]
        )
        XCTAssertTrue(result.isError, result.content)
        XCTAssertTrue(result.content.contains("covered by"), result.content)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testAZeroBudgetTurnsTheDefaultCheckOff() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(overlay: keypad))
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "hittable_timeout_ms": "0", "effect_timeout_ms": "0"]
        )
        XCTAssertFalse(result.isError, result.content)
        let reads = await driver.hierarchyReads
        XCTAssertEqual(reads, 0)
    }

    func testASlowHierarchyDoesNotHoldUpTheDefaultTap() async {
        let driver = TapCheckDriver(
            target: Self.addButton, hierarchy: screen(overlay: keypad), hierarchyDelay: .seconds(5)
        )
        let started = ContinuousClock.now
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "hittable_timeout_ms": "200"]
        )
        XCTAssertFalse(result.isError, "an unchecked tap proceeds: \(result.content)")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        let taps = await driver.taps
        XCTAssertEqual(taps.count, 1)
    }

    func testAnElementBeyondItsClippingContainerIsClipped() {
        let pillTab = ElementInfo(
            id: "tab.settings", label: "Settings", type: .button, frame: Rect(x: 500, y: 20, width: 100, height: 40)
        )
        let pill = ViewNode(
            id: "pill", type: .tabBar, frame: Rect(x: 100, y: 10, width: 465, height: 60),
            children: [ViewNode(id: "tab.settings", label: "Settings", type: .button, frame: pillTab.frame)]
        )
        let root = ViewNode(
            id: "root", type: .other, frame: Rect(x: 0, y: 0, width: 1024, height: 768), children: [pill]
        )
        XCTAssertEqual(
            TapHittability.block(for: pillTab, at: Point(x: 586, y: 40), in: root),
            .clipped(by: "tabBar 'pill'")
        )
        XCTAssertNil(TapHittability.block(for: pillTab, at: Point(x: 540, y: 40), in: root))
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

    func testNoObservableChangeIsReportedByDefault() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen())
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Semantic snapshot unchanged"), result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["observable_change"]?.boolValue, false)
    }

    func testAChangedScreenIsConfirmed() async {
        let changed = ViewNode(id: "root", type: .other, frame: Self.window, children: [
            ViewNode(id: "detail", label: "Day detail", type: .other, frame: Self.window)
        ])
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(), hierarchyAfterTap: changed)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add"]
        )
        XCTAssertFalse(result.content.contains("Semantic snapshot unchanged"), result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["observable_change"]?.boolValue, true)
    }

    func testAChangeThatLandsAfterTheTapStillCounts() async {
        let changed = ViewNode(id: "root", type: .other, frame: Self.window, children: [
            ViewNode(id: "detail", label: "Day detail", type: .other, frame: Self.window)
        ])
        // The first post-tap read still shows the old screen (a transition under way).
        let driver = TapCheckDriver(
            target: Self.addButton, hierarchy: screen(), hierarchyAfterTap: changed, staleReadsAfterTap: 2
        )
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add"]
        )
        XCTAssertEqual(result.structuredContent?.objectValue?["observable_change"]?.boolValue, true, result.content)
    }

    func testCheckEffectFalseSkipsTheAfterRead() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen())
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "check_effect": "false"]
        )
        XCTAssertFalse(result.content.contains("Semantic snapshot unchanged"), result.content)
        XCTAssertNil(result.structuredContent?.objectValue?["observable_change"])
    }
}

private actor TapCheckDriver: PlatformDriver {
    private let target: ElementInfo
    private let hierarchy: ViewNode
    private let keyboardVisible: Bool
    private let hierarchyDelay: Swift.Duration?
    private let hierarchyAfterTap: ViewNode?
    private var staleReadsAfterTap: Int
    private var foregrounds: [String]
    private var summaries: [String]
    private(set) var taps: [Point] = []
    private(set) var hierarchyReads = 0

    init(
        target: ElementInfo,
        hierarchy: ViewNode,
        keyboardVisible: Bool = false,
        foregrounds: [String] = ["com.jot", "com.jot"],
        summaries: [String] = ["Home", "Home"],
        hierarchyDelay: Swift.Duration? = nil,
        hierarchyAfterTap: ViewNode? = nil,
        staleReadsAfterTap: Int = 0
    ) {
        self.hierarchyDelay = hierarchyDelay
        self.hierarchyAfterTap = hierarchyAfterTap
        self.staleReadsAfterTap = staleReadsAfterTap
        self.target = target
        self.hierarchy = hierarchy
        self.keyboardVisible = keyboardVisible
        self.foregrounds = foregrounds
        self.summaries = summaries
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil)
    }

    /// A precise selector finds the target; an empty one lists the screen, whose title row follows
    /// the scripted summaries so a test can make "the screen" change or stay put.
    func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        guard selector.id == nil, selector.label == nil, selector.containsText == nil else { return [target] }
        let title = summaries.count > 1 ? summaries.removeFirst() : (summaries.first ?? "")
        return [target, ElementInfo(id: "title", label: title)]
    }

    func tap(at point: Point) async throws {
        taps.append(point)
    }

    func isKeyboardVisible() async throws -> Bool {
        keyboardVisible
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        hierarchyReads += 1
        if let hierarchyDelay {
            try await Task.sleep(for: hierarchyDelay)
        }
        if !taps.isEmpty, let hierarchyAfterTap {
            if staleReadsAfterTap > 0 {
                staleReadsAfterTap -= 1
                return hierarchy
            }
            return hierarchyAfterTap
        }
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
