// swiftlint:disable multiline_arguments
@testable import CLI
import Foundation
import MCPServer
import XCTest

/// The flow runner's own behaviour — waits, screenshots, `on_error`, variables, multi-device
/// parsing — driven through a fake executor so none of it needs a device.
final class FlowRunnerTests: XCTestCase {
    private actor RecordingExecutor: ToolExecutor {
        private(set) var calls: [(tool: String, arguments: [String: String])] = []
        private var failing: Set<String>
        private var screenSummaries: [String]

        init(failing: Set<String> = [], screenSummaries: [String] = ["home"]) {
            self.failing = failing
            self.screenSummaries = screenSummaries
        }

        func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
            calls.append((toolName, arguments))
            if toolName == "get_screen_context" {
                let summary = screenSummaries.count > 1 ? screenSummaries.removeFirst() : screenSummaries[0]
                return .success(summary)
            }
            return failing.contains(toolName) ? .error("\(toolName) boom") : .success("\(toolName) ok")
        }
    }

    private func flow(_ steps: [TestFlow.Step], onError: TestFlow.OnError = .stop) -> TestFlow {
        TestFlow(platform: "ios", onError: onError, steps: steps)
    }

    private func context(
        variables: [String: String] = [:], output: URL? = nil, environment: [String: String] = [:]
    ) -> FlowRunContext {
        var context = FlowRunContext(variables: variables, environment: environment, outputDirectory: output)
        context.sleep = { _ in }
        return context
    }

    // MARK: - decoding

    func testArgumentsMayBeJSONNumbersAndBooleans() throws {
        let decoded = try JSONDecoder().decode(TestFlow.self, from: Data("""
        { "platform": "ios", "vars": { "n": 3 }, "on_error": "continue", "steps": [
          { "tool": "assert_visible", "on_error": "stop", "repeat": 2,
            "arguments": { "id": "x", "timeout_ms": 5000, "first": true, "scale": 0.5 } } ] }
        """.utf8))

        let step = decoded.steps[0]
        XCTAssertEqual(step.arguments["timeout_ms"], "5000")
        XCTAssertEqual(step.arguments["first"], "true")
        XCTAssertEqual(step.arguments["scale"], "0.5")
        XCTAssertEqual(step.onError, .stop)
        XCTAssertEqual(step.repeatCount, 2)
        XCTAssertEqual(decoded.onError, .continue)
        XCTAssertEqual(decoded.vars["n"], "3")
    }

    // MARK: - on_error

    func testStopsAtTheFirstFailureByDefault() async {
        let executor = RecordingExecutor(failing: ["tap_element"])
        let result = await runFlowSteps(
            flow([.init(tool: "tap_element"), .init(tool: "press_back")]), executor: executor, context: context()
        )

        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(result.stopped)
        let calls = await executor.calls
        XCTAssertEqual(calls.map(\.tool), ["tap_element"])
    }

    func testContinuesPastAFailedStepWhenTheStepSaysSo() async {
        let executor = RecordingExecutor(failing: ["tap_element"])
        let result = await runFlowSteps(
            flow([.init(tool: "tap_element", onError: .continue), .init(tool: "press_back")]),
            executor: executor, context: context()
        )

        XCTAssertEqual(result.passed, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertFalse(result.stopped)
        XCTAssertFalse(result.succeeded, "a continued failure still fails the run")
    }

    /// A step whose outcome does not matter to the check neither stops nor fails the run.
    func testAFailedOptionalStepIsReportedButDoesNotFailTheRun() async throws {
        let executor = RecordingExecutor(failing: ["dismiss_keyboard"])
        let result = await runFlowSteps(
            flow([.init(tool: "dismiss_keyboard", optional: true), .init(tool: "press_back")]),
            executor: executor, context: context()
        )

        XCTAssertEqual(result.passed, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.optionalFailed, 1)
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.lines.first?.contains("(optional)") == true, "\(result.lines)")

        let decoded = try JSONDecoder().decode(TestFlow.Step.self, from: Data(#"{"tool": "x", "optional": true}"#.utf8))
        XCTAssertTrue(decoded.optional)
        let written = try String(bytes: JSONEncoder().encode(TestFlow.Step(tool: "x")), encoding: .utf8)
        XCTAssertFalse(written?.contains("optional") == true, "only steps that set it carry it")
    }

    /// A tap whose outcome the next step asserts skips its own after-tap read; any other tap, or one
    /// that chose a check, keeps it.
    func testATapFollowedByAnAssertionLeavesTheEffectCheckToTheAssertion() async {
        let executor = RecordingExecutor()
        _ = await runFlowSteps(
            flow([
                .init(tool: "tap_element", arguments: ["id": "a"]),
                .init(tool: "assert_visible", arguments: ["id": "b"]),
                .init(tool: "tap_element", arguments: ["id": "c"]),
                .init(tool: "press_back"),
                .init(tool: "tap_element", arguments: ["id": "d", "check_effect": "true"]),
                .init(tool: "wait_for", arguments: ["id": "e"]),
                .init(tool: "tap_element", arguments: ["id": "f"]),
                .init(tool: "wait_for", arguments: ["idle": "true"]),
                .init(tool: "tap_element", arguments: ["id": "g"]),
                .init(tool: "scroll_to_element", arguments: ["id": "h"])
            ]),
            executor: executor, context: context()
        )
        let taps = await executor.calls.filter { $0.tool == "tap_element" }
        XCTAssertEqual(taps.map { $0.arguments["check_effect"] }, ["false", nil, "true", nil, "false"])
    }

    func testFlowLevelContinueAppliesToEveryStep() async {
        let executor = RecordingExecutor(failing: ["tap_element"])
        let result = await runFlowSteps(
            flow([.init(tool: "tap_element"), .init(tool: "press_back")], onError: .continue),
            executor: executor, context: context()
        )

        XCTAssertEqual(result.passed, 1)
        XCTAssertEqual(result.failed, 1)
    }

    func testRepeatRunsAStepThatManyTimes() async {
        let executor = RecordingExecutor()
        let result = await runFlowSteps(
            flow([.init(tool: "press_back", repeatCount: 3)]), executor: executor, context: context()
        )

        XCTAssertEqual(result.passed, 3)
        XCTAssertTrue(result.lines[2].contains("[3/3]"), result.lines.joined(separator: "\n"))
    }

    // MARK: - variables

    func testVariablesInterpolateInsideLongerValuesAndFallBackToTheEnvironment() async {
        let executor = RecordingExecutor()
        _ = await runFlowSteps(
            flow([.init(tool: "set_text", arguments: ["value": "user-${n}@${HOST}"])]),
            executor: executor,
            context: context(variables: ["n": "7"], environment: ["HOST": "example.com"])
        )

        let calls = await executor.calls
        XCTAssertEqual(calls.first?.arguments["value"], "user-7@example.com")
    }

    func testAMissingVariableFailsTheStepWithoutRunningIt() async {
        let executor = RecordingExecutor()
        let result = await runFlowSteps(
            flow([.init(tool: "set_text", arguments: ["value": "${nope}"])]), executor: executor, context: context()
        )

        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(result.lines[0].contains("nope"), result.lines[0])
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - flow-only steps

    func testWaitForAnElementBecomesATimedVisibilityAssertion() async {
        let executor = RecordingExecutor()
        _ = await runFlowSteps(
            flow([.init(tool: "wait_for", arguments: ["id": "home.title"])]), executor: executor, context: context()
        )

        let calls = await executor.calls
        XCTAssertEqual(calls.first?.tool, "assert_visible")
        XCTAssertEqual(calls.first?.arguments["id"], "home.title")
        XCTAssertEqual(calls.first?.arguments["timeout_ms"], "10000")
    }

    func testWaitForIdleReturnsOnceTheScreenStopsChanging() async {
        let executor = RecordingExecutor(screenSummaries: ["blank", "loading", "home", "home", "home"])
        let result = await runFlowSteps(
            flow([.init(tool: "wait_for", arguments: ["idle": "true", "stable_ms": "500"])]),
            executor: executor, context: context()
        )

        XCTAssertTrue(result.succeeded, result.lines.joined(separator: "\n"))
        let calls = await executor.calls
        XCTAssertEqual(calls.count, 5)
    }

    func testWaitForIdleTimesOutWhileTheScreenKeepsChanging() async {
        let executor = RecordingExecutor(screenSummaries: (0 ..< 100).map(String.init))
        let result = await runFlowSteps(
            flow([.init(tool: "wait_for", arguments: ["idle": "true", "timeout_ms": "1000"])]),
            executor: executor, context: context()
        )

        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(result.lines[0].contains("still changing"), result.lines[0])
    }

    func testWaitNeedsADuration() async {
        let result = await runFlowSteps(
            flow([.init(tool: "wait")]), executor: RecordingExecutor(), context: context()
        )
        XCTAssertEqual(result.failed, 1)
    }

    func testScreenshotIsNumberedByStepAndNamedFromTheStep() async throws {
        let scratch = try makeScratchDirectory()
        let executor = RecordingExecutor()
        let result = await runFlowSteps(
            flow([.init(tool: "press_back"), .init(name: "Day Detail: sheet", tool: "screenshot")]),
            executor: executor, context: context(output: scratch.url.appending(path: "shots"))
        )

        XCTAssertTrue(result.succeeded, result.lines.joined(separator: "\n"))
        let calls = await executor.calls
        let shot = try XCTUnwrap(calls.last)
        XCTAssertEqual(shot.tool, "take_screenshot")
        XCTAssertEqual(shot.arguments["return_image"], "false")
        XCTAssertTrue(shot.arguments["output"]?.hasSuffix("/shots/02-day-detail-sheet.png") == true, "\(shot)")
    }

    func testScreenshotWithoutAnOutputDirectoryExplainsWhatToPass() async {
        let result = await runFlowSteps(
            flow([.init(tool: "screenshot")]), executor: RecordingExecutor(), context: context()
        )
        XCTAssertTrue(result.lines[0].contains("--output-dir"), result.lines[0])
    }

    func testFileStemsAreSafe() {
        XCTAssertEqual(flowFileStem("  Reports / Custom!! "), "reports-custom")
        XCTAssertEqual(flowFileStem("***"), "screen")
    }

    // MARK: - plans and parsing

    func testPlanGenerationDropsWaitsAndTurnsWaitForIntoAnAssertion() {
        XCTAssertNil(flowStepForPlan(.init(tool: "wait", arguments: ["duration_ms": "500"])))
        XCTAssertNil(flowStepForPlan(.init(tool: "screenshot")))
        XCTAssertNil(flowStepForPlan(.init(tool: "wait_for", arguments: ["idle": "true"])))
        XCTAssertEqual(flowStepForPlan(.init(tool: "wait_for", arguments: ["id": "x"]))?.tool, "assert_visible")
        XCTAssertEqual(flowStepForPlan(.init(tool: "tap_element", arguments: ["id": "x"]))?.tool, "tap_element")
    }

    func testDevicesListParsesPortsAndRejectsGarbage() throws {
        let targets = try flowDeviceTargets(from: "AAA,BBB:22112")
        XCTAssertEqual(targets, [
            FlowDeviceTarget(parsing: "AAA"), FlowDeviceTarget(parsing: "BBB:22112")
        ].compactMap(\.self))
        XCTAssertEqual(targets[1].port, 22112)
        XCTAssertThrowsError(try flowDeviceTargets(from: "AAA:notaport"))
        XCTAssertEqual(try flowDeviceTargets(from: nil), [])
    }

    func testCLIParsesTheNewFlowFlagsBeforeTouchingADevice() async {
        let result = await CLIApp().run(args: ["flow", "/no/such.amoo.json", "--var", "badvalue"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("--var expects name=value"), result.output)
    }
}

// swiftlint:enable multiline_arguments
