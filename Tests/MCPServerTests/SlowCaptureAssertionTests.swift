import AmooCore
import MCP
@testable import MCPServer
import XCTest

/// On an Android home screen with an endless shimmer, one hierarchy capture ran past the
/// companion's walk limit and `assert_visible timeout_ms=60000` gave up after 9.6s. A capture that
/// ran out of time is now retried until the caller's timeout; one that hit a structural limit is not.
final class SlowCaptureAssertionTests: XCTestCase {
    private static let title = ElementInfo(id: "home.top_bar", label: "Home", type: .other)

    func testSlowCaptureIsRetriedUntilOneCompletes() async {
        let driver = SlowCaptureDriver(failures: 2, error: Self.timeLimit)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible", arguments: ["id": "home.top_bar", "timeout_ms": "5000"]
        )
        XCTAssertFalse(result.isError, result.content)
        let reads = await driver.reads
        XCTAssertEqual(reads, 3)
    }

    func testCaptureThatNeverCompletesReportsTheLastObservationAtTheTimeout() async {
        let driver = SlowCaptureDriver(failures: .max, error: Self.timeLimit)
        let started = ContinuousClock.now
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible", arguments: ["id": "home.top_bar", "timeout_ms": "800"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("time limit exceeded"), result.content)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(700))
    }

    func testStructuralLimitIsNotRetried() async {
        let driver = SlowCaptureDriver(
            failures: .max,
            error: AmooError.commandFailed(
                command: "findElements",
                output: "Hierarchy capture incomplete: depth limit 120 exceeded after 900 nodes"
            )
        )
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible", arguments: ["id": "home.top_bar", "timeout_ms": "5000"]
        )
        XCTAssertTrue(result.isError)
        let reads = await driver.reads
        XCTAssertEqual(reads, 1)
    }

    private static let timeLimit = AmooError.commandFailed(
        command: "findElements", output: "Hierarchy capture incomplete: time limit exceeded after 61 nodes"
    )
}

private actor SlowCaptureDriver: PlatformDriver {
    private var failures: Int
    private let error: any Error
    private(set) var reads = 0

    init(failures: Int, error: any Error) {
        self.failures = failures
        self.error = error
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil)
    }

    func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        reads += 1
        if failures > 0 {
            failures -= 1
            throw error
        }
        return [ElementInfo(id: "home.top_bar", label: "Home", type: .other)]
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "com.exampleapp", targetBundleID: "com.exampleapp")
    }
}
