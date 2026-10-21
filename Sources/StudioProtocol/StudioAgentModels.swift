import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds the tool-calling model for a provider profile.
public enum StudioAgentModels {
    public static func model(
        for provider: StudioProviderProfile,
        transport: any StudioHTTPTransport = StudioHTTP.live(),
        environment: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
    ) -> any StudioAgentModel {
        let http = StudioModelHTTP(provider: provider, transport: transport, environment: environment)
        return switch provider.kind {
        case .anthropic: AnthropicAgentModel(http: http)
        case .ollama: OllamaAgentModel(http: http)
        case .openAI, .custom: OpenAICompatibleAgentModel(http: http)
        }
    }
}

/// Request plumbing shared by the provider clients: endpoint, credentials, JSON body, and a
/// streamed response that reports provider errors with their body.
struct StudioModelHTTP: Sendable {
    let provider: StudioProviderProfile
    let transport: any StudioHTTPTransport
    let environment: @Sendable (String) -> String?

    func stream(path: String, body: [String: StudioJSON]) async throws -> AsyncThrowingStream<String, Error> {
        guard var url = URL(string: provider.baseUrl) else { throw StudioChatError.invalidEndpoint }
        url.append(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        try provider.authorize(&request, environment: environment)
        request.httpBody = try JSONEncoder().encode(StudioJSON.object(body))
        let (response, lines) = try await transport.lines(for: request)
        guard let http = response as? HTTPURLResponse else { throw StudioChatError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            var excerpt = ""
            for try await line in lines {
                excerpt += line
                if excerpt.count > 1024 {
                    break
                }
            }
            throw StudioChatError.requestFailed(http.statusCode, String(excerpt.prefix(1024)))
        }
        return lines
    }

    /// The payload of a server-sent-events `data:` line, or the line itself when a server streams
    /// bare JSON lines; nil for `event:` lines, comments, and blank lines.
    static func eventPayload(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("data:") {
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed.hasPrefix("{") ? trimmed : nil
    }

    /// A provider error carried inside a successful stream.
    static func streamedError(_ json: StudioJSON) -> StudioChatError? {
        if let message = json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue {
            return .requestFailed(200, message)
        }
        return nil
    }

    /// Model-written tool arguments: a JSON object, or empty when the model sent nothing or garbage.
    static func arguments(fromJSONText text: String) -> [String: StudioJSON] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
              case let .object(fields)? = StudioJSON.parse(text) else {
            return [:]
        }
        return fields
    }
}

/// OpenAI Chat Completions with tool calling; also serves OpenAI-compatible endpoints.
struct OpenAICompatibleAgentModel: StudioAgentModel {
    let http: StudioModelHTTP

    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    func respond(
        system: String,
        messages: [StudioAgentMessage],
        tools: [StudioAgentToolSpec],
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> StudioAgentTurn {
        var body: [String: StudioJSON] = [
            "model": .string(http.provider.model),
            "stream": .bool(true),
            "messages": .array([.object(["role": "system", "content": .string(system)])] + messages.flatMap(Self.wire))
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map(Self.wire))
        }
        // Some OpenAI-compatible servers reject unknown fields, so usage is requested only from OpenAI.
        if http.provider.kind == .openAI {
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }
        var text = ""
        var calls: [Int: PartialCall] = [:]
        var inputTokens: Int?
        var outputTokens: Int?
        for try await line in try await http.stream(path: "chat/completions", body: body) {
            guard let payload = StudioModelHTTP.eventPayload(line), payload != "[DONE]",
                  let json = StudioJSON.parse(payload) else { continue }
            if let error = StudioModelHTTP.streamedError(json) {
                throw error
            }
            if let usage = json["usage"], usage != .null {
                inputTokens = usage["prompt_tokens"]?.intValue ?? inputTokens
                outputTokens = usage["completion_tokens"]?.intValue ?? outputTokens
            }
            guard let choice = json["choices"]?.arrayValue?.first,
                  let delta = choice["delta"] ?? choice["message"] else { continue }
            if let content = delta["content"]?.stringValue, !content.isEmpty {
                text += content
                await onText(content)
            }
            for call in delta["tool_calls"]?.arrayValue ?? [] {
                let index = call["index"]?.intValue ?? calls.count
                var partial = calls[index] ?? PartialCall()
                if let id = call["id"]?.stringValue, !id.isEmpty {
                    partial.id = id
                }
                partial.name += call["function"]?["name"]?.stringValue ?? ""
                partial.arguments += call["function"]?["arguments"]?.stringValue ?? ""
                calls[index] = partial
            }
        }
        let toolCalls = calls.sorted { $0.key < $1.key }.map { _, partial in
            StudioAgentToolCall(
                id: partial.id.isEmpty ? "call-\(UUID().uuidString)" : partial.id,
                name: partial.name,
                arguments: StudioModelHTTP.arguments(fromJSONText: partial.arguments)
            )
        }
        return .init(text: text, toolCalls: toolCalls, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    static func wire(_ tool: StudioAgentToolSpec) -> StudioJSON {
        .object([
            "type": "function",
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters
            ])
        ])
    }

    static func wire(_ message: StudioAgentMessage) -> [StudioJSON] {
        switch message {
        case let .user(text):
            return [.object(["role": "user", "content": .string(text)])]
        case let .assistant(text, toolCalls):
            var fields: [String: StudioJSON] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
            if !toolCalls.isEmpty {
                fields["tool_calls"] = .array(toolCalls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": "function",
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string(StudioJSON.object(call.arguments).jsonText)
                        ])
                    ])
                })
            }
            return [.object(fields)]
        case let .toolResult(callId, _, content, isError):
            return [.object([
                "role": "tool",
                "tool_call_id": .string(callId),
                "content": .string(isError ? "Error: \(content)" : content)
            ])]
        }
    }
}

extension StudioJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}
