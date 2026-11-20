// swiftlint:disable multiline_arguments
import AmooCore
@testable import AmooTools
import Foundation
import TestCommons
import TestSession
import XCTest

final class ReviewBoundaryTests: XCTestCase {
    func testScreenTokenDetectsChangesBeyondSummary() {
        var children = (0 ..< 20).map { ViewNode(id: "node-\($0)", label: "Row \($0)", children: []) }
        let original = ScreenObservation(hierarchy: ViewNode(id: "root", label: "Home", children: children))
        children[19].value = "changed"
        let changed = ScreenObservation(hierarchy: ViewNode(id: "root", label: "Home", children: children))
        XCTAssertEqual(original.context.summary, changed.context.summary)
        XCTAssertNotEqual(original.token, changed.token)
        XCTAssertEqual(changed.token, ScreenObservation(hierarchy: changed.hierarchy).token)
    }

    func testKnownSecretsAreRemovedFromEveryRecordedChannel() async throws {
        let session = TestSession(
            id: "redaction", appID: "app", deviceID: "device", platform: .ios,
            driver: MockDriver(), launchArguments: ["", "--password=launch-secret"],
            launchEnvironment: ["API_TOKEN": "environment-secret"], cleanup: {}
        )
        await session.record(SessionAction(
            timestamp: Date(), toolName: "find_elements", arguments: ["label": "typed-secret"],
            result: "typed-secret environment-secret launch-secret", isError: false,
            observedElements: [RecordedElement(id: "field", label: "typed-secret", frame: nil, hitPoint: nil)]
        ))
        // A later text entry must also redact observations recorded before it was recognized.
        await session.registerSecret("typed-secret")
        let report = await SessionReport.make(from: session)
        let encoded = try SessionReport.makeJSONEncoder().encode(report)
        let text = try XCTUnwrap(String(bytes: encoded, encoding: .utf8))
        for secret in ["typed-secret", "environment-secret", "launch-secret"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertTrue(text.contains("<redacted>"))
    }

    func testNonfiniteCoordinatesNeverReachDriver() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        for raw in ["nan", "inf", "-inf"] {
            let result = await executor.execute(toolName: "tap", arguments: ["x": raw, "y": "10"])
            XCTAssertEqual(result.structuredContent?.objectValue?["code"]?.stringValue, "invalid_argument")
        }
        let calls = await driver.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancelledDeviceOperationDoesNotMutate() async {
        let queue = DeviceOperationQueue()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await queue.run(key: "device") { .success("mutated") }
        }
        let result = await task.value
        XCTAssertEqual(result.structuredContent?.objectValue?["code"]?.stringValue, "cancelled")
    }

    func testScreenshotStructuredFieldsMatchAdvertisedSchema() async throws {
        let executor = DriverToolExecutor(driver: MockDriver())
        let server = ToolCatalog(executor: executor)
        let result = await server.execute(toolName: "take_screenshot", arguments: [:])
        let schema = try XCTUnwrap(server.toolDefinitions().first { $0.name == "take_screenshot" }?.outputSchema)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertTrue(Set(fields.keys).isSubset(of: Set(schema.properties.keys)))
        XCTAssertTrue(Set(schema.required).isSubset(of: Set(fields.keys)))
    }
}

// swiftlint:enable multiline_arguments
