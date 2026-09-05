import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

final class ReviewRegressionTests: XCTestCase {
    func testInvalidSessionNeverUsesDefaultDriver() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let result = await executor.execute(toolName: "tap", arguments: ["x": "1", "y": "2", "session_id": "missing"])
        XCTAssertTrue(result.isError)
        let calls = await driver.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(result.structuredContent?.objectValue?["code"]?.stringValue, "session_not_found")
    }

    func testClosedSessionNeverUsesDefaultDriver() async throws {
        let driver = MockDriver()
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let session = try await manager.startSession(appID: "app", platform: .ios)
        try await manager.endSession(session.id)
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let result = await executor.execute(
            toolName: "type_text",
            arguments: ["text": "secret", "session_id": session.id]
        )
        XCTAssertEqual(result.structuredContent?.objectValue?["code"]?.stringValue, "session_closed")
        let calls = await driver.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testDuplicateMutationIsRejected() async {
        let driver = VerificationDriver(values: [""], duplicates: true)
        let executor = DriverToolExecutor(driver: driver)
        let result = await executor.execute(toolName: "tap_element", arguments: ["label": "Delete"])
        XCTAssertEqual(result.structuredContent?.objectValue?["code"]?.stringValue, "ambiguous_selector")
        let mutations = await driver.mutations
        XCTAssertEqual(mutations, 0)
    }

    func testTruncatedTextIsNotVerified() async {
        let driver = VerificationDriver(values: ["", "123"])
        let executor = DriverToolExecutor(driver: driver)
        let result = await executor.execute(toolName: "set_text", arguments: ["id": "field", "value": "12345"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["verification_mode"]?.stringValue, "unverified")
    }

    func testDelayedExactValueIsVerified() async {
        let driver = VerificationDriver(values: ["", "", "12345"])
        let executor = DriverToolExecutor(driver: driver)
        let result = await executor.execute(toolName: "set_text", arguments: ["id": "field", "value": "12345"])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["verification_mode"]?.stringValue, "exact")
    }

    func testMaskedChangeIsNeverClaimedAsExactVerification() async {
        let driver = VerificationDriver(values: ["", "•••"], secure: true)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "set_text", arguments: ["id": "field", "value": "abc"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["verification_mode"]?.stringValue, "masked_change")
        XCTAssertEqual(result.structuredContent?.objectValue?["verified"], .bool(false))
    }

    func testAppDomainWordsAreNotFilteredAsSystemUI() async {
        let executor = DriverToolExecutor(driver: MockDriver())
        let values = ["Set timer", "Battery dashboard", "System settings"].map { ElementInfo(id: $0, label: $0) }
        let filtered = await executor.filterAppRelevantElements(values)
        XCTAssertEqual(filtered, values)
    }

    func testScreenshotCanBeSavedWithoutInlineImage() async {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let result = await DriverToolExecutor(driver: MockDriver()).execute(
            toolName: "take_screenshot", arguments: ["output": output.path, "return_image": "false"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertNil(result.image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }
}

private actor VerificationDriver: PlatformDriver {
    private var values: [String]
    private let duplicates: Bool
    private let secure: Bool
    private(set) var mutations = 0

    init(values: [String], duplicates: Bool = false, secure: Bool = false) {
        self.values = values
        self.duplicates = duplicates
        self.secure = secure
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        let value = values.count > 1 ? values.removeFirst() : values[0]
        let element = ElementInfo(id: "field", label: "Field", value: value, isSecureTextEntry: secure)
        return duplicates ? [element, element] : [element]
    }

    func setText(_: ElementSelector, text _: String) async throws {
        mutations += 1
    }

    func tap(at _: Point) async throws {
        mutations += 1
    }
}
