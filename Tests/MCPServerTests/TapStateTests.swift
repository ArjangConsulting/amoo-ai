import AmooCore
import MCP
@testable import MCPServer
import XCTest

private actor TapStateDriver: PlatformDriver {
    var selected = false
    let duplicate: Bool

    init(duplicate: Bool = false) {
        self.duplicate = duplicate
    }

    func tap(at _: Point) async throws {
        selected.toggle()
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        let element = ElementInfo(
            id: "choice",
            label: "Choice",
            type: .button,
            frame: Rect(x: 0, y: 0, width: 44, height: 44),
            isSelected: selected,
            semantics: ElementSemantics(isChecked: selected)
        )
        return duplicate ? [element, element] : [element]
    }
}

final class TapStateTests: XCTestCase {
    func testTapReturnsStateObservedAfterDispatchWithoutClaimingAssertion() async throws {
        let executor = DriverToolExecutor(driver: TapStateDriver())
        let result = await executor.execute(toolName: "tap_element", arguments: ["id": "choice"])
        XCTAssertFalse(result.isError, result.content)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["target_state"]?.objectValue?["selected"], .bool(true))
        XCTAssertEqual(fields["target_state"]?.objectValue?["checked"], .bool(true))
        XCTAssertEqual(fields["postcondition_verified"], .bool(false))
    }

    func testAmbiguousPostTapObservationDoesNotChooseFirstMatch() async {
        let driver = TapStateDriver(duplicate: true)
        let executor = DriverToolExecutor(driver: driver)
        let state = await executor.observedTapState(ElementInfo(id: "choice", label: "Choice"), driver: driver)
        XCTAssertEqual(state, .null)
    }

    func testDisablingEffectCheckSkipsStateRead() async {
        let executor = DriverToolExecutor(driver: TapStateDriver())
        let result = await executor.execute(
            toolName: "tap_element", arguments: ["id": "choice", "check_effect": "false"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertNil(result.structuredContent?.objectValue?["target_state"])
    }
}
