import AmooCore
@testable import AmooTools
import XCTest

/// With the keyboard up, a scroll through the screen's centre lands on keys and moves nothing. Scrolls
/// drag through the area above the keyboard instead.
final class ScrollAboveKeyboardTests: XCTestCase {
    func testTheAreaAboveTheKeyboardIsTheScreenDownToItsTopEdge() {
        let screen = Rect(x: 0, y: 0, width: 440, height: 956)
        let area = DriverToolExecutor.areaAbove(keyboard: Rect(x: 0, y: 600, width: 440, height: 356), in: screen)
        XCTAssertEqual(area, Rect(x: 0, y: 0, width: 440, height: 600))
        XCTAssertEqual(DriverToolExecutor.areaAbove(keyboard: nil, in: screen), screen)
        XCTAssertEqual(
            DriverToolExecutor.areaAbove(keyboard: Rect(x: 0, y: 80, width: 440, height: 876), in: screen),
            screen,
            "too little room above the keyboard keeps the ordinary scroll"
        )
    }

    func testScrollDragsAboveAVisibleKeyboard() async {
        let driver = KeyboardScrollDriver(keyboardUp: true)
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "scroll", arguments: ["direction": "down", "distance": "300"])
        XCTAssertFalse(result.isError, result.content)
        let gestures = await driver.gestures
        XCTAssertEqual(gestures, ["drag 220.0,450.0 -> 220.0,150.0"], "a 300-point drag centred at y=300, above y=600")
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
    private(set) var gestures: [String] = []

    init(keyboardUp: Bool) {
        self.keyboardUp = keyboardUp
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
        return ViewNode(id: "root", children: keyboardUp ? [keyboard] : [])
    }

    func drag(from: Point, to: Point, duration _: Duration, holdDuration _: Duration) async throws {
        gestures.append("drag \(from.x),\(from.y) -> \(to.x),\(to.y)")
    }

    func scroll(direction: Direction, distance: Double) async throws {
        gestures.append("scroll \(direction.rawValue) \(distance)")
    }
}
