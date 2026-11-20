import AmooCore
@testable import AmooTools
import XCTest

/// With the keyboard up, a scroll through the screen's centre lands on keys and moves nothing. Scrolls
/// drag through the area above the keyboard instead.
final class ScrollAboveKeyboardTests: XCTestCase {
    private let screen = Rect(x: 0, y: 0, width: 440, height: 956)
    private let keyboard = ViewNode(
        id: "UIKeyboardLayoutStar Preview",
        frame: Rect(x: 0, y: 600, width: 440, height: 356)
    )

    func testTheAreaIsTheTargetsScrollViewClippedAboveTheKeyboard() {
        let card = ViewNode(id: "card.1440", type: .button, frame: Rect(x: 16, y: 1212, width: 408, height: 282))
        let header = ViewNode(id: "header", type: .scrollView, frame: Rect(x: 0, y: 0, width: 440, height: 110))
        let list = ViewNode(
            id: "results", type: .scrollView, frame: Rect(x: 0, y: 230, width: 440, height: 726), children: [card]
        )
        let root = ViewNode(id: "root", children: [header, list, keyboard])
        let area = DriverToolExecutor.keyboardScrollArea(in: root, screen: screen, targetID: "card.1440")
        XCTAssertEqual(area, Rect(x: 0, y: 230, width: 440, height: 370), "the list from y=230 down to the keyboard")
        let largest = DriverToolExecutor.keyboardScrollArea(in: root, screen: screen, targetID: nil)
        XCTAssertEqual(largest, area, "without a target the largest scroll view, never the header")
    }

    func testNoKeyboardOrNoRoomAboveItKeepsTheOrdinaryScroll() {
        XCTAssertNil(DriverToolExecutor.keyboardScrollArea(in: ViewNode(id: "root"), screen: screen, targetID: nil))
        let tall = ViewNode(id: "UIKeyboardLayoutStar Preview", frame: Rect(x: 0, y: 80, width: 440, height: 876))
        XCTAssertNil(DriverToolExecutor.keyboardScrollArea(
            in: ViewNode(id: "root", children: [tall]), screen: screen, targetID: nil
        ))
    }

    func testScrollDragsAboveAVisibleKeyboard() async {
        let driver = KeyboardScrollDriver(keyboardUp: true)
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "scroll", arguments: ["direction": "down", "distance": "300"])
        XCTAssertFalse(result.isError, result.content)
        let gestures = await driver.gestures
        XCTAssertEqual(gestures, ["drag 220.0,450.0 -> 220.0,150.0"], "a 300-point drag centred at y=300, above y=600")
    }

    func testAKeyboardMissingFromTheTreeIsPlacedFromItsShiftKey() async {
        let driver = KeyboardScrollDriver(keyboardUp: true, keyboardInTree: false)
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "scroll", arguments: ["direction": "down", "distance": "300"])
        XCTAssertFalse(result.isError, result.content)
        let gestures = await driver.gestures
        // Shift at y=772 puts the keyboard's top at 582; the drag is centred in 0...582.
        XCTAssertEqual(gestures, ["drag 220.0,441.0 -> 220.0,141.0"])
    }

    func testScrollWithoutAKeyboardUsesTheCompanionScroll() async {
        let driver = KeyboardScrollDriver(keyboardUp: false)
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "scroll", arguments: ["direction": "down", "distance": "300"])
        XCTAssertFalse(result.isError, result.content)
        let gestures = await driver.gestures
        XCTAssertEqual(gestures, ["scroll down 300.0"])
    }
}

/// A 440x956 screen whose keyboard, when up, covers everything below y=600.
actor KeyboardScrollDriver: PlatformDriver {
    private let keyboardUp: Bool
    private let keyboardInTree: Bool
    private(set) var gestures: [String] = []

    init(keyboardUp: Bool, keyboardInTree: Bool = true) {
        self.keyboardUp = keyboardUp
        self.keyboardInTree = keyboardInTree
    }

    func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        guard keyboardUp, selector.id == "shift" else { return [] }
        let frame = Rect(x: 4, y: 772, width: 50, height: 46)
        return [ElementInfo(id: "shift", label: "shift", type: .button, frame: frame)]
    }

    func isKeyboardVisible() async throws -> Bool {
        keyboardUp
    }

    func screenGeometry() async throws -> ScreenSize {
        ScreenSize(widthPoints: 440, heightPoints: 956, widthPixels: 1320, heightPixels: 2868, scale: 3)
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        let keys = ViewNode(id: "q", label: "q", type: .button, frame: Rect(x: 4, y: 610, width: 40, height: 50))
        let keyboard = ViewNode(
            id: "UIKeyboardLayoutStar Preview",
            frame: Rect(x: 0, y: 600, width: 440, height: 356),
            children: [keys]
        )
        return ViewNode(id: "root", children: keyboardUp && keyboardInTree ? [keyboard] : [])
    }

    func drag(from: Point, to: Point, duration _: Duration, holdDuration _: Duration) async throws {
        gestures.append("drag \(from.x),\(from.y) -> \(to.x),\(to.y)")
    }

    func scroll(direction: Direction, distance: Double) async throws {
        gestures.append("scroll \(direction.rawValue) \(distance)")
    }
}
