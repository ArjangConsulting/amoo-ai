import AmooTools
@testable import CLI
import Foundation
import XCTest

/// Variables that refer to other variables, and how an optional step's failure is printed.
final class FlowVariableTests: XCTestCase {
    private actor RecordingExecutor: ToolExecutor {
        private(set) var calls: [(tool: String, arguments: [String: String])] = []

        func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
            calls.append((toolName, arguments))
            return .success("\(toolName) ok")
        }
    }

    private func flow(_ steps: [TestFlow.Step]) -> TestFlow {
        TestFlow(platform: "ios", steps: steps)
    }

    private func context(variables: [String: String] = [:], environment: [String: String] = [:]) -> FlowRunContext {
        var context = FlowRunContext(variables: variables, environment: environment)
        context.sleep = { _ in }
        return context
    }

    func testAVariableInsideAnotherVariablesValueIsResolved() async {
        let executor = RecordingExecutor()
        _ = await runFlowSteps(
            flow([.init(tool: "device_launch_app", arguments: ["environment": "${launch_env}"])]),
            executor: executor,
            context: context(
                variables: ["launch_env": "MOCK_SESSION=${session},HOST=${HOST}", "session": "s-42"],
                environment: ["HOST": "h", "SECRET": "p${w}d"]
            )
        )

        let calls = await executor.calls
        XCTAssertEqual(calls.first?.arguments["environment"], "MOCK_SESSION=s-42,HOST=h")
    }

    func testAnEnvironmentValueIsTakenAsWritten() throws {
        let resolved = try interpolateFlowVariables(in: "${SECRET}", variables: [:], environment: ["SECRET": "p${w}d"])

        XCTAssertEqual(resolved, "p${w}d")
    }

    func testAVariableThatRefersToItselfFailsTheStep() async {
        let executor = RecordingExecutor()
        let result = await runFlowSteps(
            flow([.init(tool: "set_text", arguments: ["value": "${a}"])]),
            executor: executor,
            context: context(variables: ["a": "x${b}", "b": "${a}"])
        )

        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(result.lines[0].contains("${a} -> ${b} -> ${a}"), result.lines[0])
        let calls = await executor.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPlanResolutionExpandsNestedFlowVariablesAndKeepsTheRest() {
        let variables = ["env": "S=${session},T=${TOKEN}", "session": "s-1", "loop": "${loop}"]

        XCTAssertEqual(resolvingFlowVariables(in: "${env}", from: variables), "S=s-1,T=${TOKEN}")
        XCTAssertEqual(resolvingFlowVariables(in: "${loop}", from: variables), "${loop}")
    }

    func testAnOptionalFailurePrintsOnlyItsFirstLine() {
        XCTAssertEqual(optionalFailureLine("one line", reported: true), "one line")
        XCTAssertEqual(
            optionalFailureLine("adb failed\njava.lang.SecurityException\n\tat a.b", reported: true),
            "adb failed (2 more line(s) in report.json)"
        )
        XCTAssertEqual(
            optionalFailureLine("adb failed\n\tat a.b", reported: false),
            "adb failed (1 more line(s); --output-dir keeps them in report.json)"
        )
    }
}
