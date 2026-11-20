import AmooCore
@testable import AmooTools
import XCTest

// swiftlint:disable multiline_arguments

/// A SwiftUI search bar's magnifier image inherits the search field's identifier, so an id selector
/// matches an image and a text field. `fill_field` and `set_text` write to the one text input.
final class FillFieldSharedIDTests: XCTestCase {
    private func fill(_ arguments: [String: String]) async -> (ToolResult, [SharedIDSearchDriver.Write]) {
        let driver = SharedIDSearchDriver()
        let result = await ToolCatalog(executor: DriverToolExecutor(driver: driver))
            .execute(toolName: "fill_field", arguments: arguments)
        return await (result, driver.writes)
    }

    func testAnIDSharedWithAnImageResolvesToTheTextField() async {
        let driver = SharedIDSearchDriver(fieldLabel: "Search query")
        let result = await ToolCatalog(executor: DriverToolExecutor(driver: driver))
            .execute(toolName: "fill_field", arguments: ["id": "home.search_field", "value": "EMP"])
        XCTAssertFalse(result.isError, result.content)
        let writes = await driver.writes
        XCTAssertEqual(writes.map(\.id), ["home.search_field"])
        XCTAssertEqual(writes.first?.label, "Search query", "the field's own label narrows the device-side write")
        XCTAssertEqual(writes.first?.text, "EMP")
    }

    func testAnUnlabeledFieldSharingItsIDIsTypedIntoAtItsOwnPosition() async {
        let driver = SharedIDSearchDriver(fieldLabel: "", existing: "EM")
        let result = await ToolCatalog(executor: DriverToolExecutor(driver: driver))
            .execute(toolName: "fill_field", arguments: ["id": "home.search_field", "value": "EMP"])
        XCTAssertFalse(result.isError, result.content)
        let writes = await driver.writes
        XCTAssertTrue(writes.isEmpty, "the device could not tell the field apart by id, so no selector write")
        let typed = await driver.typed
        XCTAssertEqual(typed, ["tap 190.0,198.0", "clear 2", "type EMP"])
        XCTAssertTrue(result.content.contains("(exact)"), result.content)
    }

    func testIndexAndFirstAreAccepted() async {
        let (byIndex, _) = await fill(["id": "home.search_field", "value": "EMP", "index": "2"])
        XCTAssertFalse(byIndex.isError, byIndex.content)
        let (first, _) = await fill(["id": "home.search_field", "value": "EMP", "first": "true"])
        XCTAssertFalse(first.content.contains("Unknown argument"), first.content)
    }

    func testTwoTextInputsStillNeedAPick() async {
        let driver = SharedIDSearchDriver(inputs: 2)
        let result = await ToolCatalog(executor: DriverToolExecutor(driver: driver))
            .execute(toolName: "fill_field", arguments: ["id": "home.search_field", "value": "EMP"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("matched"), result.content)
    }
}

/// An image and one (or two) text fields sharing an identifier, the way SwiftUI exposes `.searchable`.
actor SharedIDSearchDriver: PlatformDriver {
    struct Write: Sendable {
        let id: String?
        let label: String?
        let text: String
    }

    private(set) var writes: [Write] = []
    private(set) var typed: [String] = []
    private var value: String
    private let inputs: Int
    private let fieldLabel: String

    init(inputs: Int = 1, fieldLabel: String = "Search", existing: String = "") {
        self.inputs = inputs
        self.fieldLabel = fieldLabel
        value = existing
    }

    func setText(_ selector: ElementSelector, text: String) async throws {
        writes.append(Write(id: selector.id, label: selector.label, text: text))
        value = text
    }

    func tap(at point: Point) async throws {
        typed.append("tap \(point.x),\(point.y)")
    }

    func clearText(characterCount: Int?) async throws {
        typed.append("clear \(characterCount ?? -1)")
        value = ""
    }

    func typeText(_ text: String) async throws {
        typed.append("type \(text)")
        value += text
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        let image = ElementInfo(
            id: "home.search_field", label: "Search", type: .image,
            frame: Rect(x: 30, y: 190, width: 16, height: 16)
        )
        let clear = ElementInfo(
            id: "home.search_field", label: "Clear search", type: .button,
            frame: Rect(x: 320, y: 190, width: 17, height: 17)
        )
        let fields = (0 ..< inputs).map { index in
            ElementInfo(
                id: "home.search_field", label: fieldLabel, value: value, type: .textField,
                frame: Rect(x: 60, y: 180 + Double(index) * 50, width: 260, height: 36)
            )
        }
        return ([image, clear] + fields).filter { element in
            selector.label.map { $0 == element.label } ?? true
        }
    }
}

// swiftlint:enable multiline_arguments
