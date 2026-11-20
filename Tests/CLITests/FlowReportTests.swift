// swiftlint:disable multiline_arguments
import AmooCore
@testable import CLI
import Foundation
import MCPServer
import XCTest

/// A failed flow step printed "see last observed state" and the state went nowhere, so every
/// failure meant probing the device again by hand. Each step is now recorded and written to
/// `<output-dir>/report.json`.
final class FlowReportTests: XCTestCase {
    private actor ScriptedExecutor: ToolExecutor {
        func execute(toolName: String, arguments _: [String: String]) async -> ToolResult {
            guard toolName == "assert_value" else { return .success("\(toolName) ok") }
            return ToolResult(
                content: "Assertion mismatch", isError: true,
                structuredContent: .object(["failure_kind": .string("assertion_mismatch")])
            )
        }
    }

    private func run(_ steps: [TestFlow.Step]) async -> FlowRunResult {
        var context = FlowRunContext(environment: [:])
        context.sleep = { _ in }
        return await runFlowSteps(
            TestFlow(platform: "ios", steps: steps), executor: ScriptedExecutor(), context: context
        )
    }

    func testRecordsEveryStepWithItsStatusAndStructuredResult() async {
        let result = await run([
            .init(name: "open", tool: "tap_element"),
            .init(tool: "dismiss_keyboard", optional: true),
            .init(name: "value", tool: "assert_value")
        ])
        XCTAssertEqual(result.steps.map(\.status), ["passed", "passed", "failed"])
        XCTAssertEqual(result.steps.map(\.name), ["open", "dismiss_keyboard", "value"])
        XCTAssertEqual(result.steps.last?.result?.objectValue?["failure_kind"], .string("assertion_mismatch"))
    }

    /// A tap whose expected element never showed passed its step, and the flow failed one step
    /// later with a misleading "no element matched".
    func testATapWhoseExpectationWasNotMetFailsTheStep() {
        let tap = ToolResult.success(
            "Tap dispatched.\nExpected 'sign_in_button' to appear within 15000ms: not observed.",
            structuredContent: .object(["expected_effect_met": .bool(false), "expectation_status": .string("not_met")])
        )
        let failed = failingUnmetExpectation(tap)
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.structuredContent?.objectValue?["failure_kind"], .string("expectation_not_met"))
        XCTAssertTrue(failed.content.contains("not observed"), failed.content)

        let met = ToolResult.success("ok", structuredContent: .object(["expected_effect_met": .bool(true)]))
        XCTAssertFalse(failingUnmetExpectation(met).isError)
        let inconclusive = ToolResult.success(
            "ok",
            structuredContent: .object(["expectation_status": .string("unverified")])
        )
        let unverified = failingUnmetExpectation(inconclusive)
        XCTAssertTrue(unverified.isError)
        XCTAssertEqual(unverified.structuredContent?.objectValue?["failure_kind"], .string("expectation_unverified"))
    }

    func testWritesTheReportIntoTheOutputDirectory() async throws {
        let scratch = try makeScratchDirectory()
        let result = await run([.init(tool: "tap_element"), .init(tool: "assert_value")])
        let report = FlowReport(
            flow: "/flows/a.amoo.json", platform: "ios", deviceID: "SIM", port: 22093, result: result,
            elapsedMilliseconds: 42
        )
        let directory = scratch.url.appending(path: "out")
        let line = writeFlowReport(report, to: directory)

        XCTAssertTrue(line.hasPrefix("Report: "), line)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "report.json"))
        ) as? [String: Any])
        XCTAssertEqual(json["failed"] as? Int, 1)
        XCTAssertEqual(json["device_id"] as? String, "SIM")
        XCTAssertEqual((json["steps"] as? [[String: Any]])?.count, 2)
    }
}

// swiftlint:enable multiline_arguments
