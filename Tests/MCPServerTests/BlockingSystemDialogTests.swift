import AmooCore
import MCP
@testable import MCPServer
import XCTest

/// A launch blocked by an Android "isn't responding" dialog reported only "frontmost app is
/// android"; finding the dialog took a screenshot and a query. These pin the named cause.
final class BlockingSystemDialogTests: XCTestCase {
    private static let anrScreen = [
        ElementInfo(id: "status_bar_container", label: ""),
        ElementInfo(id: "alertTitle", label: "Settings isn't responding"),
        ElementInfo(id: "aerr_close", label: "Close app", type: .button),
        ElementInfo(id: "aerr_wait", label: "Wait", type: .button)
    ]

    func testRecognisesTheFrameworksANRDialog() {
        let dialog = BlockingSystemDialog.find(in: Self.anrScreen)
        XCTAssertEqual(dialog?.title, "Settings isn't responding")
        XCTAssertEqual(dialog?.actions, ["aerr_close: Close app", "aerr_wait: Wait"])
    }

    func testAnOrdinaryAlertIsNotABlockingSystemDialog() {
        XCTAssertNil(BlockingSystemDialog.find(in: [ElementInfo(id: "alertTitle", label: "Delete entry?")]))
    }

    func testLaunchBlockedByTheDialogNamesIt() async {
        let driver = FrontmostDriver(frontmost: "android", elements: Self.anrScreen)
        let result = await DriverToolExecutor(driver: driver).verifyLaunch(
            appID: "com.novalingo.android.qa", driver: driver, timeoutMS: 300
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Settings isn't responding"), result.content)
        XCTAssertTrue(result.content.contains("aerr_wait"), result.content)
        XCTAssertNotNil(result.structuredContent?.objectValue?["blocking_dialog"])
    }

    func testLaunchWithTheCompanionInFrontPointsAtRecovery() async {
        let driver = FrontmostDriver(frontmost: "com.amoo.companion", elements: [])
        let result = await DriverToolExecutor(driver: driver).verifyLaunch(
            appID: "com.novalingo.android.qa", driver: driver, timeoutMS: 300
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("env up --runtime-id"), result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["failure_scope"], .string("companion_channel"))
    }

    func testCurrentAppNamesTheDialog() async {
        let driver = FrontmostDriver(frontmost: "android", elements: Self.anrScreen)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "current_app", arguments: [:])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Settings isn't responding"), result.content)
    }

    func testCurrentAppWithTheAppInFrontDoesNotQuery() async {
        let driver = FrontmostDriver(frontmost: "com.novalingo.android.qa", elements: Self.anrScreen)
        _ = await DriverToolExecutor(driver: driver).execute(toolName: "current_app", arguments: [:])
        let queries = await driver.queries
        XCTAssertEqual(queries, 0)
    }
}

private actor FrontmostDriver: PlatformDriver {
    private let frontmost: String
    private let elements: [ElementInfo]
    private(set) var queries = 0

    init(frontmost: String, elements: [ElementInfo]) {
        self.frontmost = frontmost
        self.elements = elements
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil)
    }

    func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        queries += 1
        return elements
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: frontmost, targetBundleID: "")
    }

    func appState(appID _: String) async throws -> AppState {
        .running
    }
}
