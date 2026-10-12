@testable import CLI
import Foundation
import StudioProtocol
import TestCodeGenerator
import TestCommons
import XCTest

// Compact inline fixtures keep each scenario's input beside its expectation.
// swiftlint:disable multiline_arguments

/// `amoo generate plan --from-flow` authors a plan from a hand-written `*.amoo.json`, so the
/// plan -> test pipeline works without ever running the MCP session recorder.
final class GeneratePlanFromFlowTests: XCTestCase {
    private let flowJSON = """
    {
      "platform": "ios",
      "steps": [
        { "name": "Launch", "tool": "device_launch_app",
          "arguments": { "app_id": "com.example.app", "launch_args": "-UITest,1",
                         "environment": "SKIP_ONBOARDING=1" } },
        { "tool": "tap_element", "arguments": { "id": "tab.reports", "index": "1" } },
        { "tool": "tap_element", "arguments": { "id": "tab.reports", "index": "1" } },
        { "tool": "set_text", "arguments": { "id": "email", "value": "user@example.com" } },
        { "tool": "assert_visible", "arguments": { "id": "reports.title" } }
      ]
    }
    """

    private func writeFlow(_ json: String) throws -> String {
        let url = try makeScratchDirectory().url.appendingPathComponent("flow.amoo.json")
        try Data(json.utf8).write(to: url)
        return url.path
    }

    private func plan(from json: String, testName: String? = "Reports Flow") throws -> StudioAuthoredTest {
        let result = try runGeneratePlanCommand(options: GeneratePlanOptions(
            flowPath: writeFlow(json), outputDirectory: nil, contextPath: nil,
            testName: testName, testDescription: nil
        ))
        XCTAssertEqual(result.exitCode, 0, result.output)
        return try JSONDecoder().decode(StudioAuthoredTest.self, from: Data(result.output.utf8))
    }

    func testCompilesAnAuthoredFlowIntoAPlanWithoutALaunchStep() throws {
        let test = try plan(from: flowJSON)
        let operations = try XCTUnwrap(test.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.map(\.tool), ["tap_element", "tap_element", "set_text", "assert_visible"])
        XCTAssertEqual(test.requirements?.appId, "com.example.app")
        XCTAssertEqual(test.requirements?.launchArguments, ["-UITest", "1"])
        XCTAssertEqual(test.requirements?.launchEnvironment, ["SKIP_ONBOARDING": "1"])
        XCTAssertEqual(test.name, "Reports Flow")
    }

    /// Two deliberate identical taps stay two steps, and the pick survives into the generated test.
    func testDuplicateStepsAndPickArgumentsReachTheGeneratedXCUITest() throws {
        let test = try plan(from: flowJSON)
        let operations = try XCTUnwrap(test.compiledPlan?.toolOperations)
        XCTAssertEqual(operations[0].arguments["index"], "1")
        let source = try XCUITestEmitter().generate(test).source
        XCTAssertTrue(
            source.contains(#"matching(identifier: "tab.reports").element(boundBy: 1)"#),
            source
        )
    }

    func testRejectsAnEmptyFlowAndAnUnknownPlatform() throws {
        let empty = try runGeneratePlanCommand(options: GeneratePlanOptions(
            flowPath: writeFlow(#"{"platform":"ios","steps":[]}"#), outputDirectory: nil, contextPath: nil,
            testName: nil, testDescription: nil
        ))
        XCTAssertEqual(empty.exitCode, 64)
        let unknown = try runGeneratePlanCommand(options: GeneratePlanOptions(
            flowPath: writeFlow(#"{"platform":"web","steps":[{"tool":"tap_element","arguments":{"id":"a"}}]}"#),
            outputDirectory: nil, contextPath: nil, testName: nil, testDescription: nil
        ))
        XCTAssertEqual(unknown.exitCode, 64)
    }

    func testWritesPlanAndFlowIntoTheOutputDirectory() throws {
        let out = try makeScratchDirectory().url.appendingPathComponent("out").path
        let result = try runGeneratePlanCommand(options: GeneratePlanOptions(
            flowPath: writeFlow(flowJSON), outputDirectory: out, contextPath: nil,
            testName: "ReportsFlow", testDescription: nil
        ))
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out + "/plan.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out + "/flow.json"))
    }

    func testFlagParsingRequiresExactlyOneInput() throws {
        let parsed = try parseGeneratePlanOptions(args: ["--from-flow", "f.amoo.json", "--out", "o"])
        XCTAssertEqual(parsed.flowPath, "f.amoo.json")
        XCTAssertNil(parsed.reportPath)
        XCTAssertThrowsError(try parseGeneratePlanOptions(args: ["--report", "r.json", "--from-flow", "f.amoo.json"]))
        XCTAssertThrowsError(try parseGeneratePlanOptions(args: ["--out", "o"]))
    }

    func testHelpDocumentsFromFlowWithAnExample() {
        let help = renderGeneratePlanHelp()
        XCTAssertTrue(help.contains("--from-flow"))
        XCTAssertTrue(help.contains("amoo generate plan --from-flow"))
    }

    /// The checked-in example flow is a valid input.
    func testShippedExampleFlowCompiles() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/sign-in.amoo.json").path
        let result = try runGeneratePlanCommand(options: GeneratePlanOptions(
            flowPath: path, outputDirectory: nil, contextPath: nil, testName: "SignIn", testDescription: nil
        ))
        XCTAssertEqual(result.exitCode, 0, result.output)
        let test = try JSONDecoder().decode(StudioAuthoredTest.self, from: Data(result.output.utf8))
        XCTAssertEqual(test.compiledPlan?.toolOperations?.count, 4)
    }
}

// swiftlint:enable multiline_arguments
