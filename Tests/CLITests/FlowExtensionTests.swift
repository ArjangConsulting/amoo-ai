import AmooCore
import AmooTools
@testable import CLI
import Foundation
import TestCommons
import XCTest

/// The flow-extension hook: `prefix.step` tools go to `amoo-ext-<prefix>`, which is described and
/// started before the first step, gets each of its steps, and is ended after the last one.
final class FlowExtensionTests: XCTestCase {
    private actor FakeInvoker: FlowExtensionInvoking {
        private(set) var calls: [(verb: String, request: Value)] = []
        private let steps: [String]
        private let failingSteps: Set<String>
        private let protocolVersion: Int

        init(
            steps: [String] = ["select_variant", "assert_request"],
            failingSteps: Set<String> = [],
            protocolVersion: Int = 1
        ) {
            self.steps = steps
            self.failingSteps = failingSteps
            self.protocolVersion = protocolVersion
        }

        func invoke(prefix _: String, verb: String, request: Value, timeout _: Swift.Duration) async throws -> Value {
            calls.append((verb, request))
            let fields = request.objectValue ?? [:]
            switch verb {
            case "describe":
                return .object(["protocol": .int(protocolVersion), "steps": .array(steps.map(Value.string))])
            case "flow_start":
                return .object([
                    "protocol": .int(1), "ok": .bool(true),
                    "state": .object(["session": .string("s-1")]),
                    "launch_environment": .object([
                        "MOQ_SESSION_ID": .string("s-1"),
                        "MOQ_BASE_URL": .string("http://m")
                    ]),
                    "vars": .object(["mock_user": .string("uid-7")])
                ])
            case "step":
                let tool = fields["step"]?.objectValue?["tool"]?.stringValue ?? ""
                let failed = failingSteps.contains(tool)
                return .object([
                    "protocol": .int(1), "ok": .bool(!failed),
                    "message": .string(failed ? "\(tool) mismatch" : "\(tool) done"),
                    "result": .object(["seen": fields["state"] ?? .null])
                ])
            default:
                return .object(["protocol": .int(1), "ok": .bool(true)])
            }
        }
    }

    private actor RecordingExecutor: ToolExecutor {
        private(set) var calls: [(tool: String, arguments: [String: String])] = []

        func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
            calls.append((toolName, arguments))
            return .success("\(toolName) ok")
        }
    }

    private func context(_ invoker: FakeInvoker) -> FlowRunContext {
        var context = FlowRunContext(variables: [:], environment: [:])
        context.sleep = { _ in }
        context.extensions = FlowExtensionSession(
            invoker: invoker,
            run: FlowExtensionRun(id: "run-1", flowPath: "/f.amoo.json", platform: "ios", deviceID: "D1")
        )
        return context
    }

    private func decodeFlow(_ json: String) throws -> TestFlow {
        try JSONDecoder().decode(TestFlow.self, from: Data(json.utf8))
    }

    // MARK: - names and decoding

    func testOnlyADottedLowercaseNameIsAnExtensionTool() {
        XCTAssertEqual(
            FlowExtensionTool(toolName: "moq.select_variant"),
            FlowExtensionTool(toolName: "moq.select_variant")
        )
        XCTAssertEqual(FlowExtensionTool(toolName: "moq.select_variant")?.executableName, "amoo-ext-moq")
        XCTAssertNil(FlowExtensionTool(toolName: "tap_element"))
        XCTAssertNil(FlowExtensionTool(toolName: "Moq.select"))
        XCTAssertNil(FlowExtensionTool(toolName: "moq.a.b"))
        XCTAssertNil(FlowExtensionTool(toolName: "moq."))
        XCTAssertNil(FlowExtensionTool(toolName: "1moq.step"))
    }

    func testExtensionStepsKeepObjectArgumentsAndDeviceToolsStillRejectThem() throws {
        let flow = try decodeFlow("""
        { "platform": "ios", "steps": [
          { "tool": "moq.assert_request",
            "arguments": { "endpoint": "GET /v1/me", "times": 1,
                           "headers": { "authorization": { "scheme": "Bearer" } } } } ] }
        """)
        let step = flow.steps[0]
        XCTAssertEqual(
            step.extensionArguments?["headers"],
            .object(["authorization": .object(["scheme": .string("Bearer")])])
        )
        XCTAssertEqual(step.arguments["times"], "1")
        XCTAssertEqual(step.arguments["headers"], #"{"authorization":{"scheme":"Bearer"}}"#)

        let reencoded = try decodeFlow(String(bytes: JSONEncoder().encode(flow), encoding: .utf8) ?? "")
        XCTAssertEqual(reencoded.steps[0].extensionArguments, step.extensionArguments)

        XCTAssertThrowsError(try decodeFlow("""
        { "platform": "ios", "steps": [ { "tool": "tap_element", "arguments": { "id": { "x": 1 } } } ] }
        """))
    }

    // MARK: - lifecycle

    func testDescribesStartsRunsAndEndsAroundTheSteps() async throws {
        let invoker = FakeInvoker()
        let executor = RecordingExecutor()
        let flow = try decodeFlow("""
        { "platform": "ios", "steps": [
          { "tool": "start_session",
            "arguments": { "app_id": "com.app", "environment": "MOQ_BASE_URL=http://flow,X=1" } },
          { "tool": "moq.select_variant", "arguments": { "endpoint": "GET /v1/me", "variant": "error" } },
          { "tool": "moq.assert_request", "arguments": { "claims": { "sub": "${mock_user}" } } } ] }
        """)

        let result = await runFlowSteps(flow, executor: executor, context: context(invoker))

        XCTAssertTrue(result.succeeded, result.lines.joined(separator: "\n"))
        let calls = await invoker.calls
        XCTAssertEqual(calls.map(\.verb), ["describe", "flow_start", "step", "step", "flow_end"])
        XCTAssertEqual(calls[1].request.objectValue?["run"]?.objectValue?["device_id"], .string("D1"))
        XCTAssertEqual(calls[2].request.objectValue?["state"], .object(["session": .string("s-1")]))
        let claims = calls[3].request.objectValue?["step"]?.objectValue?["arguments"]?.objectValue?["claims"]
        XCTAssertEqual(claims, .object(["sub": .string("uid-7")]))
        XCTAssertEqual(calls[4].request.objectValue?["passed"], .bool(true))
        XCTAssertEqual(result.steps[1].tool, "moq.select_variant")
        XCTAssertEqual(result.steps[1].result, .object(["seen": .object(["session": .string("s-1")])]))

        let launch = await executor.calls[0]
        let environment = AppLaunchEnvironment.parse(launch.arguments["environment"])
        XCTAssertEqual(environment, ["MOQ_BASE_URL": "http://flow", "MOQ_SESSION_ID": "s-1", "X": "1"])
    }

    func testAFailedExtensionStepFailsTheRunAndStillEndsTheExtension() async throws {
        let invoker = FakeInvoker(failingSteps: ["assert_request"])
        let flow = try decodeFlow("""
        { "platform": "ios", "steps": [ { "tool": "moq.assert_request" }, { "tool": "press_back" } ] }
        """)

        let result = await runFlowSteps(flow, executor: RecordingExecutor(), context: context(invoker))

        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(result.stopped)
        XCTAssertTrue(result.lines[0].contains("assert_request mismatch"))
        let calls = await invoker.calls
        XCTAssertEqual(calls.last?.verb, "flow_end")
        XCTAssertEqual(calls.last?.request.objectValue?["passed"], .bool(false))
    }

    func testAStepTheExtensionDoesNotOfferFailsBeforeAnyStepRuns() async throws {
        let invoker = FakeInvoker(steps: ["select_variant"])
        let executor = RecordingExecutor()
        let flow = try decodeFlow("""
        { "platform": "ios", "steps": [ { "tool": "press_back" }, { "tool": "moq.reset_everything" } ] }
        """)

        let result = await runFlowSteps(flow, executor: executor, context: context(invoker))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.lines[0].contains("moq.reset_everything is not a step"), result.lines[0])
        let deviceCalls = await executor.calls
        XCTAssertTrue(deviceCalls.isEmpty)
        let verbs = await invoker.calls.map(\.verb)
        XCTAssertEqual(verbs, ["describe"])
    }

    func testAnotherProtocolVersionIsRejected() async throws {
        let invoker = FakeInvoker(protocolVersion: 2)
        let flow = try decodeFlow(#"{ "platform": "ios", "steps": [ { "tool": "moq.select_variant" } ] }"#)

        let result = await runFlowSteps(flow, executor: RecordingExecutor(), context: context(invoker))

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.lines[0].contains("protocol 2"), result.lines[0])
    }

    func testALaunchEnvironmentWrittenAsAVariableKeepsTheFlowsKeys() async throws {
        let invoker = FakeInvoker()
        let executor = RecordingExecutor()
        let flow = try decodeFlow("""
        { "platform": "ios", "vars": { "launch_env": "MOQ_BASE_URL=http://flow,X=1" }, "steps": [
          { "tool": "device_launch_app", "arguments": { "app_id": "com.app", "environment": "${launch_env}" } },
          { "tool": "moq.select_variant" } ] }
        """)
        var context = context(invoker)
        context.variables = flow.vars

        let result = await runFlowSteps(flow, executor: executor, context: context)

        XCTAssertTrue(result.succeeded, result.lines.joined(separator: "\n"))
        let launch = await executor.calls[0]
        let environment = AppLaunchEnvironment.parse(launch.arguments["environment"])
        XCTAssertEqual(environment, ["MOQ_BASE_URL": "http://flow", "MOQ_SESSION_ID": "s-1", "X": "1"])
    }

    func testADeclaredExtensionStartsWithoutAStepOfItsOwn() async throws {
        let invoker = FakeInvoker()
        let executor = RecordingExecutor()
        let flow = try decodeFlow("""
        { "platform": "ios", "extensions": ["moq"], "steps": [
          { "tool": "device_launch_app", "arguments": { "app_id": "com.app" } } ] }
        """)

        let result = await runFlowSteps(flow, executor: executor, context: context(invoker))

        XCTAssertTrue(result.succeeded, result.lines.joined(separator: "\n"))
        let verbs = await invoker.calls.map(\.verb)
        XCTAssertEqual(verbs, ["describe", "flow_start", "flow_end"])
        let launch = await executor.calls[0]
        XCTAssertEqual(AppLaunchEnvironment.parse(launch.arguments["environment"])["MOQ_SESSION_ID"], "s-1")
        XCTAssertEqual(flow.extensionPrefixes, ["moq"])
    }

    func testADeclaredExtensionMustBeAPrefixName() {
        XCTAssertThrowsError(try decodeFlow("""
        { "platform": "ios", "extensions": ["Moq.x"], "steps": [ { "tool": "press_back" } ] }
        """))
    }

    func testTheAppEndsBeforeTheExtensionEndsEvenWhenAStepFailed() async throws {
        for failing in [Set<String>(), ["assert_request"]] {
            let invoker = FakeInvoker(failingSteps: failing)
            let executor = RecordingExecutor()
            let flow = try decodeFlow("""
            { "platform": "ios", "terminate_app_at_end": true, "steps": [
              { "tool": "device_launch_app", "arguments": { "app_id": "com.example.app" } },
              { "tool": "moq.assert_request" }, { "tool": "press_back" } ] }
            """)

            let result = await runFlowSteps(flow, executor: executor, context: context(invoker))

            let calls = await executor.calls
            XCTAssertEqual(calls.last?.tool, "device_terminate_app", "\(failing)")
            XCTAssertEqual(calls.last?.arguments["app_id"], "com.example.app")
            let end = await invoker.calls.last
            XCTAssertEqual(end?.verb, "flow_end")
            XCTAssertEqual(end?.request.objectValue?["app_terminated"], .bool(true))
            XCTAssertEqual(end?.request.objectValue?["passed"], .bool(failing.isEmpty))
            XCTAssertEqual(result.succeeded, failing.isEmpty)
        }
    }

    func testWithoutTheOptionNothingIsEndedAndTheExtensionIsTold() async throws {
        let invoker = FakeInvoker()
        let executor = RecordingExecutor()
        let flow = try decodeFlow("""
        { "platform": "ios", "steps": [
          { "tool": "device_launch_app", "arguments": { "app_id": "com.example.app" } },
          { "tool": "moq.select_variant" } ] }
        """)

        _ = await runFlowSteps(flow, executor: executor, context: context(invoker))

        let tools = await executor.calls.map(\.tool)
        XCTAssertFalse(tools.contains("device_terminate_app"))
        let end = await invoker.calls.last
        XCTAssertEqual(end?.request.objectValue?["app_terminated"], .bool(false))
    }

    // MARK: - process invoker

    func testTheProcessInvokerFindsTheProgramOnTheExtensionPathAndSendsTheRequest() async throws {
        let scratch = try makeScratchDirectory()
        let program = scratch.url.appending(path: "amoo-ext-echo")
        try """
        #!/bin/sh
        input=$(cat)
        printf '{"protocol":1,"ok":true,"message":"%s","verb":"%s"}' "$(printf '%s' "$input" | wc -c | tr -d ' ')" "$1"
        """.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let invoker = ProcessFlowExtensionInvoker(environment: [
            "AMOO_EXTENSION_PATH": scratch.url.path,
            "PATH": "/usr/bin:/bin"
        ])

        let reply = try await invoker.invoke(
            prefix: "echo",
            verb: "describe",
            request: .object(["a": .int(1)]),
            timeout: .seconds(10)
        )

        XCTAssertEqual(reply.objectValue?["verb"], .string("describe"))
        XCTAssertEqual(reply.objectValue?["message"], .string("7"))
        XCTAssertThrowsError(try invoker.executablePath(for: "missing")) { error in
            XCTAssertTrue("\(error)".contains("amoo-ext-missing is not installed"))
        }
    }
}
