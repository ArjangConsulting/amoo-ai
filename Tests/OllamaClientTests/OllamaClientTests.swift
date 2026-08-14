import Foundation
@testable import OllamaClient
import Testing

struct OllamaClientTests {
    @Test("Chat sends Ollama JSON and parses tool calls")
    func chatRequestAndResponse() async throws {
        let responseData = Data(#"""
        {
          "message": {
            "role": "assistant",
            "content": "done",
            "tool_calls": [{"function": {"name": "tap", "arguments": {"x": 12, "enabled": true}}}]
          },
          "done_reason": "stop"
        }
        """#.utf8)
        let transport = MockOllamaTransport(responses: [
            .success((responseData, httpResponse(statusCode: 200)))
        ])
        let client = OllamaClient(baseURL: baseURL, transport: transport)
        let tool = OllamaTool(
            name: "tap",
            description: "Tap the screen",
            parameters: OllamaToolParameters(
                properties: ["x": .init(type: "integer", description: "X coordinate")],
                required: ["x"]
            )
        )

        let response = try await client.chat(
            model: "qwen3.5",
            messages: [.init(role: .user, content: "Tap it", toolCallID: "call-1")],
            tools: [tool]
        )

        #expect(response.role == "assistant")
        #expect(response.content == "done")
        #expect(response.doneReason == "stop")
        #expect(response.hasToolCalls)
        #expect(response.toolCalls.first?.name == "tap")
        #expect(response.toolCalls.first?.arguments == ["x": "12", "enabled": "1"])

        let request = try #require(await transport.requests.first)
        #expect(request.url == baseURL.appendingPathComponent("api/chat"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "qwen3.5")
        #expect(json["stream"] as? Bool == false)
        #expect((json["messages"] as? [[String: Any]])?.first?["tool_call_id"] as? String == "call-1")
        #expect((json["tools"] as? [[String: Any]])?.count == 1)
    }

    @Test("Chat omits tools and reports HTTP failures")
    func chatHTTPError() async throws {
        let transport = MockOllamaTransport(responses: [
            .success((Data("model missing".utf8), httpResponse(statusCode: 404)))
        ])
        let client = OllamaClient(baseURL: baseURL, transport: transport)

        await #expect(throws: OllamaError.self) {
            try await client.chat(model: "missing", messages: [])
        }

        let body = try #require(await transport.requests.first?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["tools"] == nil)
    }

    @Test("Chat rejects malformed responses")
    func malformedChatResponse() async {
        let transport = MockOllamaTransport(responses: [
            .success((Data(#"{"done":true}"#.utf8), httpResponse(statusCode: 200)))
        ])
        let client = OllamaClient(baseURL: baseURL, transport: transport)

        await #expect(throws: OllamaError.self) {
            try await client.chat(model: "model", messages: [])
        }
    }

    @Test("Availability handles healthy, unhealthy, and failed requests")
    func availability() async {
        let transport = MockOllamaTransport(responses: [
            .success((Data(), httpResponse(statusCode: 200))),
            .success((Data(), httpResponse(statusCode: 503))),
            .failure(TestError.failed)
        ])
        let client = OllamaClient(baseURL: baseURL, transport: transport)

        #expect(await client.isAvailable())
        #expect(await !client.isAvailable())
        #expect(await !client.isAvailable())
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url == baseURL.appendingPathComponent("api/tags") })
        #expect(requests.allSatisfy { $0.timeoutInterval == 3 })
    }

    @Test("Model listing parses names and tolerates malformed payloads")
    func listModels() async throws {
        let transport = MockOllamaTransport(responses: [
            .success((
                Data(#"{"models":[{"name":"qwen3.5"},{"name":"gemma3"},{}]}"#.utf8),
                httpResponse(statusCode: 200)
            )),
            .success((Data(#"{"unexpected":[]}"#.utf8), httpResponse(statusCode: 200)))
        ])
        let client = OllamaClient(baseURL: baseURL, transport: transport)

        #expect(try await client.listModels() == ["qwen3.5", "gemma3"])
        #expect(try await client.listModels().isEmpty)
    }

    @Test("Tool bridge preserves schemas")
    func toolBridge() throws {
        let tools = ToolBridge.toOllamaTools([
            .init(
                name: "type_text",
                description: "Types text",
                properties: [
                    .init(key: "text", type: "string", description: "Text to enter"),
                    .init(key: "submit", type: "boolean", description: "Submit afterward")
                ],
                required: ["text"]
            )
        ])

        let tool = try #require(tools.first)
        #expect(tool.name == "type_text")
        #expect(tool.description == "Types text")
        #expect(tool.parameters.required == ["text"])
        #expect(tool.parameters.properties["submit"]?.type == "boolean")
        #expect(tool.parameters.properties["text"]?.description == "Text to enter")
    }

    @Test("Errors provide actionable descriptions")
    func errorDescriptions() {
        #expect(OllamaError.invalidResponse.description == "Invalid response from Ollama")
        #expect(OllamaError.httpError(statusCode: 500, body: "broken").description == "Ollama HTTP 500: broken")
        #expect(OllamaError.parseError("missing").description == "Failed to parse Ollama response: missing")
        #expect(OllamaError.modelNotAvailable("qwen").description.contains("ollama pull qwen"))
        #expect(OllamaError.connectionFailed.description.contains("ollama serve"))
    }
}

private let baseURL = URL(string: "http://127.0.0.1:11434") ?? URL(fileURLWithPath: "/")

private func httpResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: baseURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)
        ?? HTTPURLResponse()
}

private enum TestError: Error {
    case failed
}

private actor MockOllamaTransport: OllamaHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var responses: [Result<(Data, URLResponse), any Error>]

    init(responses: [Result<(Data, URLResponse), any Error>]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw TestError.failed
        }
        return try responses.removeFirst().get()
    }
}
