import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol OllamaHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// swift-corelibs-foundation's `URLSession.data(for:)` takes an extra `delegate` parameter on
/// Linux, so it can't satisfy `OllamaHTTPTransport` via a direct `extension URLSession` the way
/// it can on Darwin. Route through a thin wrapper instead so both platforms compile identically.
private struct URLSessionTransport: OllamaHTTPTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// HTTP client for Ollama's `/api/chat` endpoint with tool-calling support.
public actor OllamaClient {
    private let baseURL: URL
    private let transport: any OllamaHTTPTransport

    public init(host: String = "127.0.0.1", port: Int = 11434) {
        baseURL = URL(string: "http://\(host):\(port)") ?? URL(fileURLWithPath: "/")
        transport = URLSessionTransport(session: URLSession(configuration: .default))
    }

    init(baseURL: URL, transport: any OllamaHTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    // MARK: - Chat Completion

    /// Sends a chat completion request with optional tools.
    /// Returns the assistant's response which may contain tool calls.
    public func chat(
        model: String,
        messages: [ChatMessage],
        tools: [OllamaTool] = []
    ) async throws -> ChatResponse {
        let endpoint = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map(\.asJSON),
            "stream": false
        ]

        if !tools.isEmpty {
            body["tools"] = tools.map(\.asJSON)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OllamaError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        return try parseChatResponse(data)
    }

    // MARK: - Health Check

    public func isAvailable() async -> Bool {
        let endpoint = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await transport.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Lists available models.
    public func listModels() async throws -> [String] {
        let endpoint = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await transport.data(for: URLRequest(url: endpoint))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { $0["name"] as? String }
    }

    // MARK: - Parsing

    private func parseChatResponse(_ data: Data) throws -> ChatResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw OllamaError.parseError("Missing 'message' field in response")
        }

        let role = message["role"] as? String ?? "assistant"
        let content = message["content"] as? String ?? ""
        var toolCalls: [ToolCall] = []

        if let calls = message["tool_calls"] as? [[String: Any]] {
            for call in calls {
                if let function = call["function"] as? [String: Any],
                   let name = function["name"] as? String {
                    let arguments = function["arguments"] as? [String: Any] ?? [:]
                    // Flatten arguments to [String: String] for ToolExecutor compatibility.
                    let stringArgs = arguments.reduce(into: [String: String]()) { result, pair in
                        result[pair.key] = "\(pair.value)"
                    }
                    toolCalls.append(ToolCall(name: name, arguments: stringArgs))
                }
            }
        }

        let doneReason = json["done_reason"] as? String

        return ChatResponse(
            role: role,
            content: content,
            toolCalls: toolCalls,
            doneReason: doneReason
        )
    }
}
