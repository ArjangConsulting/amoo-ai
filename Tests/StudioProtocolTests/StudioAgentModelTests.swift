import Foundation
@testable import StudioProtocol
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Streamed provider responses are fixtures that must stay byte-for-byte on one line each.
// swiftlint:disable line_length

@Suite("Agent model clients")
struct StudioAgentModelTests {
    private let tools = [StudioAgentToolSpec(schema: grammarTestCatalog.tools[1])]

    @Test("OpenAI streams text, assembles split tool-call arguments, and reports usage")
    func openAIStreaming() async throws {
        let transport = CannedTransport(body: """
        data: {"choices":[{"delta":{"content":"Checking "}}]}
        data: {"choices":[{"delta":{"content":"the screen."}}]}
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"swipe_in_direction","arguments":"{\\"direc"}}]}}]}
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"tion\\":\\"up\\"}"}}]}}]}
        data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30}}
        data: [DONE]
        """)
        let model = StudioAgentModels.model(
            for: provider(.openAI),
            transport: transport,
            environment: { _ in "sk-test" }
        )
        let streamed = TextCollector()

        let turn = try await model
            .respond(system: "sys", messages: [.user("Swipe up")], tools: tools) { await streamed.append($0) }

        #expect(turn.text == "Checking the screen.")
        #expect(await streamed.text == "Checking the screen.")
        #expect(turn.toolCalls == [StudioAgentToolCall(
            id: "call_1",
            name: "swipe_in_direction",
            arguments: ["direction": "up"]
        )])
        #expect(turn.inputTokens == 120)
        #expect(turn.outputTokens == 30)
        let request = try #require(await transport.lastBody)
        #expect(request["model"] == "gpt-test")
        #expect(request["stream_options"]?["include_usage"] == .bool(true))
        #expect(request["tools"]?.arrayValue?.first?["function"]?["name"] == "swipe_in_direction")
        #expect(await transport.lastAuthorization == "Bearer sk-test")
    }

    @Test("OpenAI messages carry tool calls and tool results in its wire format")
    func openAIWire() {
        let call = StudioAgentToolCall(id: "call_1", name: "tap_element", arguments: ["id": "login"])
        let assistant = OpenAICompatibleAgentModel.wire(.assistant(text: "", toolCalls: [call]))
        let result = OpenAICompatibleAgentModel.wire(.toolResult(
            callId: "call_1",
            name: "tap_element",
            content: "No match",
            isError: true
        ))

        #expect(assistant.first?["content"] == .null)
        #expect(assistant.first?["tool_calls"]?.arrayValue?.first?["function"]?["arguments"] == #"{"id":"login"}"#)
        #expect(result.first?["role"] == "tool")
        #expect(result.first?["tool_call_id"] == "call_1")
        #expect(result.first?["content"] == "Error: No match")
    }

    @Test("Custom OpenAI-compatible endpoints are not sent stream_options")
    func customEndpoint() async throws {
        let transport = CannedTransport(body: "data: [DONE]")
        let model = StudioAgentModels.model(for: provider(.custom), transport: transport, environment: { _ in "key" })

        _ = try await model.respond(system: "", messages: [.user("hi")], tools: []) { _ in }

        #expect(await transport.lastBody?["stream_options"] == nil)
        #expect(await transport.lastBody?["tools"] == nil)
    }

    @Test("Anthropic streams text and tool_use input deltas")
    func anthropicStreaming() async throws {
        let transport = CannedTransport(body: """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":200,"output_tokens":1}}}
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Swiping."}}
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"swipe_in_direction","input":{}}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"direction\\":"}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"down\\"}"}}
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}
        data: {"type":"message_stop"}
        """)
        let model = StudioAgentModels.model(
            for: provider(.anthropic),
            transport: transport,
            environment: { _ in "ant-key" }
        )

        let turn = try await model.respond(system: "sys", messages: [.user("Swipe down")], tools: tools) { _ in }

        #expect(turn.text == "Swiping.")
        #expect(turn.toolCalls == [StudioAgentToolCall(
            id: "toolu_1",
            name: "swipe_in_direction",
            arguments: ["direction": "down"]
        )])
        #expect(turn.inputTokens == 200)
        #expect(turn.outputTokens == 42)
        #expect(await transport.lastBody?["system"] == "sys")
        #expect(await transport.lastBody?["tools"]?.arrayValue?.first?["input_schema"]?["type"] == "object")
        #expect(await transport.lastAPIKey == "ant-key")
    }

    @Test("Anthropic merges consecutive tool results into one user turn")
    func anthropicWire() {
        let first = StudioAgentToolCall(id: "a", name: "tap_element", arguments: ["id": "x"])
        let second = StudioAgentToolCall(id: "b", name: "assert_visible", arguments: [:])
        let wire = AnthropicAgentModel.wire([
            .user("Go"),
            .assistant(text: "", toolCalls: [first, second]),
            .toolResult(callId: "a", name: "tap_element", content: "ok", isError: false),
            .toolResult(callId: "b", name: "assert_visible", content: "missing", isError: true),
            .user("Continue")
        ])

        #expect(wire.map { $0["role"] } == ["user", "assistant", "user"])
        let results = wire[2]["content"]?.arrayValue ?? []
        #expect(results.map { $0["type"] } == ["tool_result", "tool_result", "text"])
        #expect(results[1]["is_error"] == .bool(true))
        #expect(wire[1]["content"]?.arrayValue?.count == 2)
    }

    @Test("Ollama reads newline-delimited chunks with complete tool calls")
    func ollamaStreaming() async throws {
        let transport = CannedTransport(body: """
        {"message":{"role":"assistant","content":"Looking"},"done":false}
        {"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"swipe_in_direction","arguments":{"direction":"left","distance":300}}}]},"done":false}
        {"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":55,"eval_count":7}
        """)
        let model = StudioAgentModels.model(for: provider(.ollama), transport: transport, environment: { _ in nil })

        let turn = try await model.respond(system: "", messages: [.user("Swipe left")], tools: tools) { _ in }

        #expect(turn.text == "Looking")
        #expect(turn.toolCalls.first?.name == "swipe_in_direction")
        #expect(turn.toolCalls.first?.stringArguments == ["direction": "left", "distance": "300"])
        #expect(turn.inputTokens == 55)
        #expect(turn.outputTokens == 7)
        #expect(await transport.lastAuthorization == nil)
    }

    @Test("HTTP failures and in-stream errors surface the provider's message")
    func failures() async {
        let refused = StudioAgentModels.model(
            for: provider(.openAI),
            transport: CannedTransport(body: #"{"error":{"message":"invalid key"}}"#, status: 401),
            environment: { _ in "bad" }
        )
        let streamed = StudioAgentModels.model(
            for: provider(.anthropic),
            transport: CannedTransport(
                body: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
            ),
            environment: { _ in "key" }
        )
        let missingKey = StudioAgentModels.model(
            for: provider(.openAI),
            transport: CannedTransport(body: ""),
            environment: { _ in nil }
        )

        await #expect(throws: StudioChatError.self) { try await ask(refused) }
        do {
            _ = try await streamed.respond(system: "", messages: [.user("hi")], tools: []) { _ in }
            Issue.record("Expected an error")
        } catch {
            #expect(String(describing: error).contains("Overloaded"))
        }
        await #expect(throws: StudioChatError.self) { try await ask(missingKey) }
    }

    @Test("argument values reach the executor as strings")
    func argumentText() {
        let call = StudioAgentToolCall(id: "1", name: "t", arguments: [
            "flag": .bool(true), "count": .double(3), "ratio": .double(0.5), "list": .array(["a"]), "none": .null
        ])

        #expect(call.stringArguments == ["flag": "true", "count": "3", "ratio": "0.5", "list": #"["a"]"#])
    }

    private func ask(_ model: any StudioAgentModel) async throws {
        _ = try await model.respond(system: "", messages: [.user("hi")], tools: []) { _ in }
    }

    private func provider(_ kind: StudioProviderKind) -> StudioProviderProfile {
        .init(
            id: "p",
            name: "Test",
            kind: kind,
            baseUrl: kind == .ollama ? "http://localhost:11434" : "https://example.test/v1",
            model: "gpt-test",
            apiKeyEnvironmentVariable: kind == .ollama ? "" : "TEST_KEY"
        )
    }
}

/// Replays a fixed response body and records the last request.
actor CannedTransport: StudioHTTPTransport {
    private let body: String
    private let status: Int
    private(set) var lastRequest: URLRequest?

    init(body: String, status: Int = 200) {
        self.body = body
        self.status = status
    }

    var lastBody: StudioJSON? {
        lastRequest?.httpBody.flatMap { String(bytes: $0, encoding: .utf8) }.flatMap(StudioJSON.parse)
    }

    var lastAuthorization: String? {
        lastRequest?.value(forHTTPHeaderField: "Authorization")
    }

    var lastAPIKey: String? {
        lastRequest?.value(forHTTPHeaderField: "x-api-key")
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let url = request.url ?? URL(fileURLWithPath: "/")
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) ??
            URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        return (Data(body.utf8), response)
    }
}

actor TextCollector {
    private(set) var text = ""

    func append(_ chunk: String) {
        text += chunk
    }
}

// swiftlint:enable line_length
