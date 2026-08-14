@testable import CLI
import Foundation
import XCTest

/// Covers the paths `amoo flow` can take before it ever opens a companion connection —
/// everything a bad flow file should be rejected on without needing a device.
final class FlowCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRejectsAnUnknownPlatformAsAUsageError() async throws {
        let path = try writeFlow("""
        { "platform": "windows", "steps": [{ "tool": "press_back", "arguments": {} }] }
        """)

        let result = await runFlowCommand(path: path)

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("windows"), result.output)
    }

    func testRejectsAFlowWithNoSteps() async throws {
        let path = try writeFlow("""
        { "platform": "ios", "steps": [] }
        """)

        let result = await runFlowCommand(path: path)

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("no steps"), result.output)
    }

    func testReportsAMissingFlowFile() async {
        let result = await runFlowCommand(path: root.appendingPathComponent("absent.amoo.json").path)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.hasPrefix("Flow failed:"), result.output)
    }

    func testReportsMalformedJSON() async throws {
        let path = try writeFlow("{ not json ")

        let result = await runFlowCommand(path: path)

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.hasPrefix("Flow failed:"), result.output)
    }

    func testFlowStepDefaultsArgumentsToEmpty() throws {
        let flow = try JSONDecoder().decode(TestFlow.self, from: Data("""
        { "platform": "android", "port": 1234, "steps": [{ "tool": "press_home", "arguments": {} }] }
        """.utf8))

        XCTAssertEqual(flow.port, 1234)
        XCTAssertNil(flow.deviceID)
        XCTAssertNil(flow.steps[0].name)
        XCTAssertEqual(flow.steps[0].arguments, [:])
    }

    // MARK: - Help

    func testHelpIsShownWithoutArgumentsAndExitsAsAUsageError() async {
        let result = await CLIApp().run(args: ["flow"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("amoo flow"), result.output)
    }

    func testExplicitHelpFlagExitsZero() async {
        let result = await CLIApp().run(args: ["flow", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("amoo flow"), result.output)
    }

    func testTooManyArgumentsIsAUsageError() async {
        let result = await CLIApp().run(args: ["flow", "a.json", "b.json"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("amoo flow"), result.output)
    }

    func testTopLevelHelpListsTheFlowCommand() {
        XCTAssertTrue(renderCLIHelp().contains("flow <path.amoo.json>"))
    }

    // MARK: - Helpers

    private func writeFlow(_ json: String) throws -> String {
        let path = root.appendingPathComponent("flow.amoo.json")
        try json.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }
}
