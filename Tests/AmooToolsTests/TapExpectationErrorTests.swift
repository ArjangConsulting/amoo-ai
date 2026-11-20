import AmooCore
@testable import AmooTools
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

extension TapChecksTests {
    /// "Not observed" could not tell an element that never appeared from one that appeared with a
    /// different label; the nearest match by id now says which.
    func testUnmetExpectationNamesTheSameIdWithItsActualLabel() async {
        let driver = TapCheckDriver(
            target: Self.addButton,
            hierarchy: screen(),
            waitTimesOut: true
        )
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element",
            arguments: ["id": "add", "expect_id": "add", "expect_label": "Done", "expect_timeout_ms": "200"]
        )
        let fields = result.structuredContent?.objectValue
        XCTAssertEqual(fields?["expectation_status"], .string("not_met"))
        XCTAssertEqual(
            fields?["expectation_nearest"]?.stringValue?.hasPrefix("[add] Add entry"),
            true,
            "\(fields ?? [:])"
        )
        XCTAssertTrue(result.content.contains("Nearest on screen: [add] Add entry"), result.content)
    }
}

extension TapChecksTests {
    /// With nothing similar in the capture, the note names the usual causes instead of leaving a probe to find them.
    func testUnmetExpectationWithNothingSimilarSuggestsWhereItCouldBe() async {
        let driver = TapCheckDriver(
            target: Self.addButton,
            hierarchy: screen(),
            waitTimesOut: true,
            missingIDs: ["sheet"]
        )
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element",
            arguments: ["id": "add", "expect_id": "sheet", "expect_label": "Done", "expect_timeout_ms": "200"]
        )
        XCTAssertNil(result.structuredContent?.objectValue?["expectation_nearest"])
        XCTAssertTrue(result.content.contains("may be off-screen"), result.content)
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
