import AmooCore
@testable import AmooTools
import XCTest

/// Once iOS's "Save Password?" sheet has settled over an app, the accessibility tree shows only the
/// application element, and a step behind it failed as a plain selector miss that did not say so.
final class OnlyRootSelectorMissTests: XCTestCase {
    private static let root = ElementInfo(id: "", label: "ExampleApp", type: .other)

    func testAMissWhereTheTreeHoldsOnlyTheApplicationSaysSo() async {
        let executor = DriverToolExecutor(driver: TreeDriver(elements: [Self.root]))
        let result = await executor.execute(toolName: "tap_element", arguments: ["id": "home.title", "timeout_ms": "1"])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["only_root_element"], .bool(true), result.content)
        XCTAssertTrue(result.content.contains("only the application element ('ExampleApp')"), result.content)
        XCTAssertTrue(result.content.contains("--disable-password-autofill"), result.content)
    }

    func testAMissOnAScreenWithControlsIsAPlainMiss() async {
        let controls = [Self.root, ElementInfo(id: "home.refresh", label: "Refresh", type: .button)]
        let executor = DriverToolExecutor(driver: TreeDriver(elements: controls))
        let result = await executor.execute(toolName: "tap_element", arguments: ["id": "home.title", "timeout_ms": "1"])

        XCTAssertTrue(result.isError)
        XCTAssertNil(result.structuredContent?.objectValue?["only_root_element"])
        XCTAssertFalse(result.content.contains("only the application element"), result.content)
    }

    func testOneControlIsNotTheRoot() {
        XCTAssertTrue(DriverToolExecutor.isOnlyTheRoot([]))
        XCTAssertTrue(DriverToolExecutor.isOnlyTheRoot([Self.root]))
        XCTAssertFalse(DriverToolExecutor.isOnlyTheRoot([ElementInfo(id: "ok", label: "OK", type: .button)]))
    }
}

/// Answers a whole-screen read with `elements` and a selector with what matches its id.
private struct TreeDriver: PlatformDriver {
    let elements: [ElementInfo]

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil)
    }

    func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        guard let id = selector.id else { return elements }
        return elements.filter { $0.id == id }
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "com.example.app", targetBundleID: "com.example.app")
    }
}
