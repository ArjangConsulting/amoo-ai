import AmooCore
import MCP
@testable import MCPServer
import XCTest

private actor TapStateDriver: PlatformDriver {
    var selected = false
    private(set) var findCalls = 0
    let duplicate: Bool

    init(duplicate: Bool = false) {
        self.duplicate = duplicate
    }

    func tap(at _: Point) async throws {
        selected.toggle()
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        let node = ViewNode(
            id: "choice",
            label: "Choice",
            type: .button,
            frame: Rect(x: 0, y: 0, width: 44, height: 44),
            semantics: ElementSemantics(isChecked: selected),
            isSelected: selected
        )
        return ViewNode(id: "root", children: duplicate ? [node, node] : [node])
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        findCalls += 1
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
        let state = await executor.observedTapState(ElementInfo(id: "choice", label: "Choice"), in: nil, driver: driver)
        XCTAssertEqual(state, .null)
    }

    func testStateComesFromTheEffectCheckReadWithoutAnotherSnapshot() async throws {
        let driver = TapStateDriver()
        let executor = DriverToolExecutor(driver: driver)
        let result = await executor.execute(toolName: "tap_element", arguments: ["id": "choice"])
        let state = try XCTUnwrap(result.structuredContent?.objectValue?["target_state"]?.objectValue)
        XCTAssertEqual(state["selected"], .bool(true))
        // Only the element lookup before the tap asks the companion to find anything.
        let findCalls = await driver.findCalls
        XCTAssertEqual(findCalls, 1)
    }

    func testAnElementGoneAfterTheTapHasNoState() async {
        let driver = TapStateDriver()
        let executor = DriverToolExecutor(driver: driver)
        let gone = ViewNode(id: "root", children: [ViewNode(id: "other", label: "Other")])
        let state = await executor.observedTapState(
            ElementInfo(id: "choice", label: "Choice"),
            in: gone,
            driver: driver
        )
        XCTAssertEqual(state, .null)
        let findCalls = await driver.findCalls
        XCTAssertEqual(findCalls, 0)
    }

    func testSeveralNodesInTheReadAreSettledByTheCompanion() async {
        let driver = TapStateDriver()
        let executor = DriverToolExecutor(driver: driver)
        let twin = ViewNode(id: "choice", label: "Choice")
        let state = await executor.observedTapState(
            ElementInfo(id: "choice", label: "Choice"), in: ViewNode(id: "root", children: [twin, twin]), driver: driver
        )
        XCTAssertNotEqual(state, .null)
        let findCalls = await driver.findCalls
        XCTAssertEqual(findCalls, 1)
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
