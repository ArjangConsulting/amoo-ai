@testable import AmooCore
import XCTest

final class ElementTypeNativeNameTests: XCTestCase {
    /// iOS companions built before explicit type names string-interpolated `XCUIElement.ElementType`,
    /// which renders as `XCUIElementType(rawValue: N)`. Every element then fell through to `other`.
    func testRawValueDescriptionsMapToTheirElementType() {
        let cases: [(String, ElementType)] = [
            ("XCUIElementType(rawValue: 9)", .button),
            ("XCUIElementType(rawValue: 42)", .button),
            ("XCUIElementType(rawValue: 49)", .textField),
            ("XCUIElementType(rawValue: 50)", .textField),
            ("XCUIElementType(rawValue: 48)", .staticText),
            ("XCUIElementType(rawValue: 43)", .image),
            ("XCUIElementType(rawValue: 75)", .cell),
            ("XCUIElementType(rawValue: 40)", .switchControl),
            ("XCUIElementType(rawValue: 33)", .slider),
            ("XCUIElementType(rawValue: 37)", .picker),
            ("XCUIElementType(rawValue: 21)", .navigationBar),
            ("XCUIElementType(rawValue: 58)", .webView),
            ("XCUIElementType(rawValue: 1)", .other)
        ]
        for (description, expected) in cases {
            XCTAssertEqual(ElementType(nativeName: description), expected, description)
        }
    }

    func testUnknownRawValuesAreNotGuessed() {
        XCTAssertNil(ElementType(nativeName: "XCUIElementType(rawValue: 999)"))
        XCTAssertNil(ElementType(nativeName: "XCUIElementType(rawValue: nope)"))
    }

    func testExplicitNamesStillMap() {
        XCTAssertEqual(ElementType(nativeName: "button"), .button)
        XCTAssertEqual(ElementType(nativeName: "switch"), .switchControl)
        XCTAssertEqual(ElementType(nativeName: "secureTextField"), .textField)
        XCTAssertEqual(ElementType(nativeName: "android.widget.Button"), .button)
    }

    /// The user-visible effect: a screen of buttons reported zero interactable elements.
    func testRawValueTypedButtonsCountAsInteractable() {
        let button = ViewNode(
            id: "Settings",
            label: "Settings",
            type: ElementType(nativeName: "XCUIElementType(rawValue: 9)"),
            frame: Rect(x: 0, y: 0, width: 44, height: 44)
        )
        let observation = ScreenObservation(hierarchy: ViewNode(id: "root", children: [button]))
        XCTAssertEqual(observation.context.interactableCount, 1)
    }
}
