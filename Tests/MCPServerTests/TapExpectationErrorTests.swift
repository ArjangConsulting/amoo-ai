import AmooCore
import MCP
@testable import MCPServer
import XCTest

/// An expectation that could not be checked said only "could not be checked on this driver", the
/// same words as a driver with no wait at all, even when the wait had failed with a readable error.
final class TapExpectationErrorTests: XCTestCase {
    func testUnverifiedExpectationCarriesTheWaitError() async {
        let driver = FailingWaitDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element",
            arguments: ["id": "play", "expect_id": "pause", "check_hittable": "false"]
        )
        XCTAssertFalse(result.isError, result.content)
        let fields = result.structuredContent?.objectValue
        XCTAssertEqual(fields?["expectation_status"], .string("unverified"))
        XCTAssertTrue(
            fields?["expectation_error"]?.stringValue?.contains("capture incomplete") == true,
            "\(fields ?? [:])"
        )
        XCTAssertTrue(result.content.contains("capture incomplete"), result.content)
    }
}

private actor FailingWaitDriver: PlatformDriver {
    private let play = ElementInfo(
        id: "play", label: "Play", type: .button, frame: Rect(x: 10, y: 10, width: 40, height: 40)
    )

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil)
    }

    func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        [play]
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func tap(at _: Point) async throws {}

    func waitForElement(_: ElementSelector, timeout _: AmooCore.Duration) async throws {
        throw AmooError.commandFailed(command: "waitForElement", output: "Hierarchy capture incomplete: time limit")
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "com.example", targetBundleID: "com.example")
    }
}
