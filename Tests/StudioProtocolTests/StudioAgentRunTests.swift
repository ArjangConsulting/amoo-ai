import Foundation
@testable import StudioProtocol
import Testing

@Suite("Agent runs")
struct StudioAgentRunTests {
    @Test("a run records a session, executes tool calls with screenshots, and ends cleanly")
    func happyPath() async throws {
        let model = ScriptedModel([
            .init(
                text: "Tapping login.",
                toolCalls: [call("tap_element", ["id": .string("login")])],
                inputTokens: 10,
                outputTokens: 5
            ),
            .init(text: "Signed in.", toolCalls: [])
        ])
        let session = FakeAgentSession()
        let (service, runId) = try await start(model: model, session: session)

        await service.waitForRun(runId)
        let result = try await service.events(.init(runId: runId))

        #expect(result.state == .completed)
        #expect(result.events.map(\.kind) == [
            .sessionStarted, .usage, .assistantMessage, .toolCall, .toolResult, .usage, .assistantMessage, .finished
        ])
        #expect(result.events.map(\.seq) == Array(0 ..< 8))
        #expect(result.nextSeq == 8)
        let toolResult = try #require(result.events.first { $0.kind == .toolResult })
        #expect(toolResult.ok == true)
        #expect(toolResult.screenshot?.path == "/tmp/screen.png")
        #expect(toolResult.gesturePoint == StudioPoint(x: 5, y: 6))
        #expect(await session.executed == [.init(
            tool: "tap_element",
            arguments: ["id": "login", "session_id": "session-1"]
        )])
        #expect(await session.ended == ["session-1"])
        #expect(result.events.last?.planPath == "/tmp/plan.json")
        #expect(result.events.last?.state == .completed)
    }

    @Test("each tool result names the session action it recorded, and run_steps is not offered")
    func actionIndexes() async throws {
        let model = ScriptedModel([
            .init(text: "", toolCalls: [call("find_elements", [:]), call("tap_element", ["id": .string("a")])]),
            .init(text: "", toolCalls: [call("swipe_in_direction", ["direction": .string("up")])]),
            .init(text: "ok", toolCalls: [])
        ])
        let (service, runId) = try await start(model: model, session: FakeAgentSession())
        await service.waitForRun(runId)

        let results = try await service.events(.init(runId: runId)).events.filter { $0.kind == .toolResult }
        #expect(results.map(\.actionIndex) == [0, 1, 2])
        #expect(await !model.toolNames.contains("run_steps"))
    }

    @Test("the model sees the user's request, then each tool result")
    func conversation() async throws {
        let model = ScriptedModel([
            .init(text: "", toolCalls: [call("find_elements", [:])]),
            .init(text: "Done", toolCalls: [])
        ])
        let (service, runId) = try await start(model: model, session: FakeAgentSession())
        await service.waitForRun(runId)

        let second = try #require(await model.received.last)
        #expect(second.first == .user("Sign in"))
        guard case let .toolResult(_, name, content, isError) = second.last else {
            Issue.record("Expected a tool result last")
            return
        }
        #expect(name == "find_elements")
        #expect(content == "ran find_elements")
        #expect(!isError)
        #expect(await model.toolNames.contains("tap_element"))
        #expect(await !model.toolNames.contains("start_session"))
    }

    @Test("read-only tools take no screenshot")
    func readOnlyNoScreenshot() async throws {
        let model = ScriptedModel([
            .init(text: "", toolCalls: [call("find_elements", [:])]),
            .init(text: "ok", toolCalls: [])
        ])
        let session = FakeAgentSession()
        let (service, runId) = try await start(model: model, session: session)
        await service.waitForRun(runId)

        #expect(await session.screens == 0)
    }

    @Test("a destructive tool waits for approval and runs only when approved")
    func approvalGranted() async throws {
        let model = ScriptedModel([
            .init(text: "", toolCalls: [call("device_uninstall_app", ["app_id": .string("dev.app")])]),
            .init(text: "ok", toolCalls: [])
        ])
        let session = FakeAgentSession()
        let (service, runId) = try await start(model: model, session: session)

        let pending = try await waitForEvent(.approvalRequired, service: service, runId: runId)
        #expect(try await service.events(.init(runId: runId)).state == .awaitingApproval)
        _ = try await service.approve(.init(runId: runId, callId: pending.callId ?? "", approved: true))
        await service.waitForRun(runId)

        let events = try await service.events(.init(runId: runId)).events
        #expect(events.first { $0.kind == .approvalResolved }?.approved == true)
        #expect(await session.executed.map(\.tool) == ["device_uninstall_app"])
    }

    @Test("a declined destructive tool is reported to the model and never runs")
    func approvalDeclined() async throws {
        let model = ScriptedModel([
            .init(text: "", toolCalls: [call("device_uninstall_app", ["app_id": .string("dev.app")])]),
            .init(text: "ok", toolCalls: [])
        ])
        let session = FakeAgentSession()
        let (service, runId) = try await start(model: model, session: session)

        let pending = try await waitForEvent(.approvalRequired, service: service, runId: runId)
        _ = try await service.approve(.init(runId: runId, callId: pending.callId ?? "", approved: false))
        await service.waitForRun(runId)

        #expect(await session.executed.isEmpty)
        guard case let .toolResult(_, _, content, isError)? = await model.received.last?.last else {
            Issue.record("Expected the declined result")
            return
        }
        #expect(isError)
        #expect(content.contains("declined"))
        await #expect(throws: StudioAgentError.self) {
            _ = try await service.approve(.init(runId: runId, callId: pending.callId ?? "", approved: true))
        }
    }

    @Test("cancelling while waiting for approval ends the session and the run")
    func cancelDuringApproval() async throws {
        let model = ScriptedModel([.init(
            text: "",
            toolCalls: [call("device_uninstall_app", ["app_id": .string("x")])]
        )])
        let session = FakeAgentSession()
        let (service, runId) = try await start(model: model, session: session)

        _ = try await waitForEvent(.approvalRequired, service: service, runId: runId)
        _ = try await service.cancel(.init(runId: runId))
        await service.waitForRun(runId)

        let result = try await service.events(.init(runId: runId))
        #expect(result.state == .cancelled)
        #expect(result.events.last?.kind == .finished)
        #expect(await session.ended == ["session-1"])
        #expect(await session.executed.isEmpty)
    }

    @Test("a model failure fails the run but still ends the session")
    func modelFailure() async throws {
        let model = ScriptedModel([], failure: StudioChatError.requestFailed(500, "boom"))
        let session = FakeAgentSession()
        let (service, runId) = try await start(model: model, session: session)
        await service.waitForRun(runId)

        let result = try await service.events(.init(runId: runId))
        #expect(result.state == .failed)
        #expect(result.events.first { $0.kind == .error }?.text?.contains("boom") == true)
        #expect(await session.ended == ["session-1"])
    }

    @Test("a session that cannot start fails the run without ending anything")
    func sessionFailure() async throws {
        let session = FakeAgentSession(startFails: true)
        let (service, runId) = try await start(model: ScriptedModel([]), session: session)
        await service.waitForRun(runId)

        let result = try await service.events(.init(runId: runId))
        #expect(result.state == .failed)
        #expect(await session.ended.isEmpty)
    }

    @Test("unknown tools are reported back to the model, which can recover")
    func unknownTool() async throws {
        let model = ScriptedModel([
            .init(text: "", toolCalls: [call("teleport", [:])]),
            .init(text: "ok", toolCalls: [])
        ])
        let session = FakeAgentSession()
        let (service, runId) = try await start(model: model, session: session)
        await service.waitForRun(runId)

        let result = try await service.events(.init(runId: runId))
        #expect(result.state == .completed)
        #expect(result.events.first { $0.kind == .toolResult }?.ok == false)
        #expect(await session.executed.isEmpty)
    }

    @Test("typed text appears in events only as its length")
    func redaction() async throws {
        let model = ScriptedModel([
            .init(text: "", toolCalls: [call("type_text", ["text": .string("hunter2")])]),
            .init(text: "ok", toolCalls: [])
        ])
        let session = FakeAgentSession()
        let (service, runId) = try await start(model: model, session: session)
        await service.waitForRun(runId)

        let toolCall = try #require(try await service.events(.init(runId: runId)).events.first { $0.kind == .toolCall })
        #expect(toolCall.arguments?["text"] == "‹7 characters›")
        #expect(await session.executed.first?.arguments["text"] == "hunter2")
    }

    @Test("the run stops after its step limit")
    func stepLimit() async throws {
        let looping = (0 ..< 5).map { _ in StudioAgentTurn(text: "", toolCalls: [call("find_elements", [:])]) }
        let (service, runId) = try await start(model: ScriptedModel(looping), session: FakeAgentSession(), maxSteps: 2)
        await service.waitForRun(runId)

        let result = try await service.events(.init(runId: runId))
        #expect(result.events.contains { $0.kind == .error && $0.text?.contains("2 model turns") == true })
        #expect(result.state == .completed)
    }

    @Test("only one run drives a device at a time, and replay returns events after a sequence number")
    func busyDeviceAndReplay() async throws {
        let model = ScriptedModel([.init(
            text: "",
            toolCalls: [call("device_uninstall_app", ["app_id": .string("x")])]
        )])
        let (service, runId) = try await start(model: model, session: FakeAgentSession())
        _ = try await waitForEvent(.approvalRequired, service: service, runId: runId)

        await #expect(throws: StudioSessionError.self) { _ = try await service.start(startRequest()) }
        let tail = try await service.events(.init(runId: runId, after: 1))
        #expect(tail.events.allSatisfy { $0.seq > 1 })
        await service.cancelAll()
    }

    @Test("requests without a user message or app are rejected")
    func invalidRequests() async {
        let service = StudioAgentService(
            session: FakeAgentSession(),
            catalog: AgentCatalog(),
            modelFactory: { _ in ScriptedModel([]) }
        )

        await #expect(throws: StudioAgentError.self) { _ = try await service.start(startRequest(message: "  ")) }
        await #expect(throws: StudioAgentError.self) { _ = try await service.start(startRequest(appId: "")) }
        await #expect(throws: StudioAgentError.self) { _ = try await service.events(.init(runId: "missing")) }
    }

    @Test("the protocol advertises and routes agent methods only when agents are configured")
    func protocolRouting() async throws {
        let agents = StudioAgentService(
            session: FakeAgentSession(),
            catalog: AgentCatalog(),
            modelFactory: { _ in ScriptedModel([]) }
        )
        let withAgents = StudioService(workspace: AutomationWorkspace(), agents: agents)
        let without = StudioService(workspace: AutomationWorkspace())

        let handshake = Data(#"{"jsonrpc":"2.0","id":1,"method":"system.handshake"}"#.utf8)
        let enabled = try #require(await JSONSerialization
            .jsonObject(with: withAgents.handle(handshake)) as? [String: Any])
        let missing = Data(#"{"jsonrpc":"2.0","id":2,"method":"agent.events","params":{"runId":"x"}}"#.utf8)
        let routed = try #require(await JSONSerialization.jsonObject(with: without.handle(missing)) as? [String: Any])

        #expect(((enabled["result"] as? [String: Any])?["capabilities"] as? [String])?.contains("agent.runs") == true)
        #expect((routed["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    // MARK: Helpers

    private func start(
        model: ScriptedModel,
        session: FakeAgentSession,
        maxSteps: Int? = nil
    ) async throws -> (StudioAgentService, String) {
        let service = StudioAgentService(session: session, catalog: AgentCatalog(), modelFactory: { _ in model })
        let result = try await service.start(startRequest(maxSteps: maxSteps))
        return (service, result.runId)
    }

    private func waitForEvent(
        _ kind: StudioAgentEventKind,
        service: StudioAgentService,
        runId: String
    ) async throws -> StudioAgentEvent {
        for _ in 0 ..< 500 {
            if let event = try await service.events(.init(runId: runId)).events.first(where: { $0.kind == kind }) {
                return event
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StudioAgentError.runNotFound("no \(kind) event")
    }
}

func startRequest(
    message: String = "Sign in",
    appId: String = "dev.app",
    maxSteps: Int? = nil
) -> StudioAgentStartRequest {
    .init(
        provider: .init(
            id: "p",
            name: "Local",
            kind: .ollama,
            baseUrl: "http://localhost:11434",
            model: "m",
            apiKeyEnvironmentVariable: ""
        ),
        messages: [.init(id: "1", role: .user, content: message)],
        activeTest: authoredTest(),
        deviceId: "sim-1",
        platform: "ios",
        appId: appId,
        maxSteps: maxSteps
    )
}

func call(_ name: String, _ arguments: [String: StudioJSON]) -> StudioAgentToolCall {
    .init(id: "call-\(UUID().uuidString)", name: name, arguments: arguments)
}

struct AgentCatalog: StudioToolCatalogProviding {
    func tools() -> [StudioToolSchema] {
        grammarTestCatalog.tools + [
            .init(
                name: "run_steps",
                title: nil,
                description: "Batch",
                category: "batch",
                readOnly: false,
                destructive: false,
                replSupported: true,
                planTool: nil,
                arguments: []
            ),
            .init(
                name: "type_text",
                title: nil,
                description: "Type",
                category: "action",
                readOnly: false,
                destructive: false,
                replSupported: true,
                planTool: "type_text",
                arguments: [.init(name: "text", type: "string", description: "Text", required: true)]
            )
        ]
    }
}

actor ScriptedModel: StudioAgentModel {
    private var turns: [StudioAgentTurn]
    private let failure: (any Error)?
    private(set) var received: [[StudioAgentMessage]] = []
    private(set) var toolNames: [String] = []

    init(_ turns: [StudioAgentTurn], failure: (any Error)? = nil) {
        self.turns = turns
        self.failure = failure
    }

    func respond(
        system _: String,
        messages: [StudioAgentMessage],
        tools: [StudioAgentToolSpec],
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> StudioAgentTurn {
        received.append(messages)
        toolNames = tools.map(\.name)
        if let failure {
            throw failure
        }
        guard !turns.isEmpty else { return .init(text: "", toolCalls: []) }
        let turn = turns.removeFirst()
        if !turn.text.isEmpty {
            await onText(turn.text)
        }
        return turn
    }
}

actor FakeAgentSession: StudioSessionDriving {
    struct Execution: Equatable {
        let tool: String
        let arguments: [String: String]
    }

    struct StartFailure: Error {}

    private let startFails: Bool
    private(set) var executed: [Execution] = []
    private(set) var ended: [String] = []
    private(set) var screens = 0

    init(startFails: Bool = false) {
        self.startFails = startFails
    }

    private(set) var specs: [StudioSessionSpec] = []
    var elements: [StudioElementSuggestion] = []

    func startSession(_ spec: StudioSessionSpec) throws -> String {
        specs.append(spec)
        if startFails {
            throw StartFailure()
        }
        return "session-1"
    }

    func execute(sessionId _: String, tool: String, arguments: [String: String]) -> StudioAgentToolOutcome {
        executed.append(.init(tool: tool, arguments: arguments))
        let structured = tool == "tap_element" ? #"{"tap_point":{"x":5,"y":6}}"# : nil
        return .init(output: "ran \(tool)", isError: false, structuredContent: structured)
    }

    func observeScreen(sessionId _: String) -> StudioScreenshot? {
        screens += 1
        return .init(path: "/tmp/screen.png", widthPixels: 10, heightPixels: 20)
    }

    func observeElements(sessionId _: String) -> [StudioElementSuggestion] {
        elements
    }

    func setElements(_ elements: [StudioElementSuggestion]) {
        self.elements = elements
    }

    func endSession(sessionId: String) -> StudioAgentSessionEnd {
        ended.append(sessionId)
        return .init(planPath: "/tmp/plan.json", flowPath: "/tmp/flow.json")
    }

    func sessionDirectory(sessionId _: String) -> URL? {
        nil
    }
}
