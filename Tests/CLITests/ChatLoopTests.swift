@testable import CLI
import Foundation
import MCPServer
@testable import OllamaClient
import Testing

private let baseURL = URL(string: "http://localhost:11434")!

private func httpResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: baseURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)
        ?? HTTPURLResponse()
}

private enum TestError: Error {
    case exhausted
}

private actor MockChatTransport: OllamaHTTPTransport {
    private var responses: [Data]

    init(responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard !responses.isEmpty else { throw TestError.exhausted }
        return (responses.removeFirst(), httpResponse(statusCode: 200))
    }
}

private actor MockChatToolExecutor: ToolExecutor {
    private(set) var calls: [(name: String, arguments: [String: String])] = []
    private var results: [ToolResult]

    init(results: [ToolResult] = []) {
        self.results = results
    }

    func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
        calls.append((toolName, arguments))
        guard !results.isEmpty else { return .success("ok") }
        return results.removeFirst()
    }
}

private func plainResponseJSON(content: String) -> Data {
    Data(#"""
    {"message": {"role": "assistant", "content": "\#(content)"}}
    """#.utf8)
}

private func toolCallResponseJSON(toolName: String) -> Data {
    Data(#"""
    {"message": {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "\#(toolName)", "arguments": {"x": "1"}}}]}}
    """#.utf8)
}

private func makeLoop(
    responses: [Data],
    executor: MockChatToolExecutor = MockChatToolExecutor(),
    maxToolCallsPerTurn: Int = 10
) -> ChatLoop {
    let transport = MockChatTransport(responses: responses)
    let client = OllamaClient(baseURL: baseURL, transport: transport)
    return ChatLoop(
        executor: executor,
        ollamaClient: client,
        toolDefinitions: [
            ToolDefinition(name: "tap", description: "Tap the screen", properties: ["x": .init(type: "string", description: "x")], required: ["x"])
        ],
        model: "qwen3.5",
        systemPrompt: "You are a helpful assistant.",
        maxToolCallsPerTurn: maxToolCallsPerTurn
    )
}

struct ChatLoopTests {
    @Test("A plain text response is appended as an assistant message")
    func plainTextResponse() async throws {
        var loop = makeLoop(responses: [plainResponseJSON(content: "Hello there")])
        loop.messages.append(.init(role: .user, content: "hi"))

        await loop.processConversationTurn()

        #expect(loop.messages.last?.role == .assistant)
        #expect(loop.messages.last?.content == "Hello there")
    }

    @Test("A tool call is executed and its result appended to the conversation")
    func toolCallIsExecuted() async throws {
        let executor = MockChatToolExecutor(results: [.success("tapped")])
        var loop = makeLoop(
            responses: [
                toolCallResponseJSON(toolName: "tap"),
                plainResponseJSON(content: "Done")
            ],
            executor: executor
        )
        loop.messages.append(.init(role: .user, content: "tap the button"))

        await loop.processConversationTurn()

        let calls = await executor.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "tap")
        #expect(calls.first?.arguments == ["x": "1"])

        // Tool result should show up as a `.tool` message before the final assistant reply.
        #expect(loop.messages.contains { $0.role == .tool && $0.content == "tapped" })
        #expect(loop.messages.last?.role == .assistant)
        #expect(loop.messages.last?.content == "Done")
    }

    @Test("Reaching the tool-call depth limit asks the model to summarize")
    func depthLimitTriggersSummaryRequest() async throws {
        let executor = MockChatToolExecutor(results: [.success("tapped")])
        var loop = makeLoop(
            responses: [toolCallResponseJSON(toolName: "tap")],
            executor: executor,
            maxToolCallsPerTurn: 1
        )
        loop.messages.append(.init(role: .user, content: "tap repeatedly"))

        await loop.processConversationTurn()

        #expect(loop.messages.contains {
            $0.role == .user && $0.content.contains("Please summarize")
        })
    }

    @Test("A transport failure stops the turn without crashing")
    func transportFailureStopsTurn() async throws {
        var loop = makeLoop(responses: [])
        loop.messages.append(.init(role: .user, content: "hi"))

        await loop.processConversationTurn()

        // No assistant reply should have been appended since the request failed.
        #expect(loop.messages.last?.role == .user)
    }

    @Test("/quit and its aliases end the loop")
    func quitCommandsEndLoop() async throws {
        var loop = makeLoop(responses: [])
        var handled = loop.handleSlashCommand("/quit")
        #expect(handled == false)
        handled = loop.handleSlashCommand("/exit")
        #expect(handled == false)
        handled = loop.handleSlashCommand("/q")
        #expect(handled == false)
    }

    @Test("/clear resets messages back to just the system prompt")
    func clearResetsMessages() async throws {
        var loop = makeLoop(responses: [])
        loop.messages.append(.init(role: .user, content: "hi"))
        loop.messages.append(.init(role: .assistant, content: "hello"))
        #expect(loop.messages.count == 3)

        let handled = loop.handleSlashCommand("/clear")

        #expect(handled)
        #expect(loop.messages.count == 1)
        #expect(loop.messages.first?.role == .system)
    }

    @Test("Unknown and known non-quit slash commands are handled without ending the loop")
    func nonQuitCommandsAreHandled() async throws {
        var loop = makeLoop(responses: [])
        var handled = loop.handleSlashCommand("/help")
        #expect(handled)
        handled = loop.handleSlashCommand("/tools")
        #expect(handled)
        handled = loop.handleSlashCommand("/history")
        #expect(handled)
        handled = loop.handleSlashCommand("/model")
        #expect(handled)
        handled = loop.handleSlashCommand("/model llama3")
        #expect(handled)
        handled = loop.handleSlashCommand("/bogus")
        #expect(handled)
    }
}
