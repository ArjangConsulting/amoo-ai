import Foundation

/// A content block of an Anthropic response while it streams.
private struct AnthropicContentBlock {
    var isToolUse = false
    var id = ""
    var name = ""
    var input = ""
}

/// Anthropic Messages with tool use, streamed as typed server-sent events.
struct AnthropicAgentModel: StudioAgentModel {
    let http: StudioModelHTTP

    /// Folds Anthropic's typed stream events into one turn.
    private struct StreamState {
        var text = ""
        var blocks: [Int: AnthropicContentBlock] = [:]
        var inputTokens: Int?
        var outputTokens: Int?

        /// Applies one event and returns any text to stream; throws for an `error` event.
        mutating func apply(_ json: StudioJSON) throws -> String? {
            switch json["type"]?.stringValue {
            case "error":
                throw StudioModelHTTP.streamedError(json) ?? StudioChatError.invalidResponse
            case "message_start":
                inputTokens = json["message"]?["usage"]?["input_tokens"]?.intValue
                outputTokens = json["message"]?["usage"]?["output_tokens"]?.intValue
            case "content_block_start":
                let block = json["content_block"]
                blocks[json["index"]?.intValue ?? blocks.count] = AnthropicContentBlock(
                    isToolUse: block?["type"]?.stringValue == "tool_use",
                    id: block?["id"]?.stringValue ?? "",
                    name: block?["name"]?.stringValue ?? ""
                )
            case "content_block_delta":
                let index = json["index"]?.intValue ?? 0
                if let partial = json["delta"]?["partial_json"]?.stringValue {
                    blocks[index, default: AnthropicContentBlock(isToolUse: true)].input += partial
                }
                if let chunk = json["delta"]?["text"]?.stringValue, !chunk.isEmpty {
                    text += chunk
                    return chunk
                }
            case "message_delta":
                outputTokens = json["usage"]?["output_tokens"]?.intValue ?? outputTokens
            default:
                break
            }
            return nil
        }

        var turn: StudioAgentTurn {
            let calls = blocks.sorted { $0.key < $1.key }.compactMap { _, block -> StudioAgentToolCall? in
                guard block.isToolUse else { return nil }
                return StudioAgentToolCall(
                    id: block.id.isEmpty ? "toolu-\(UUID().uuidString)" : block.id,
                    name: block.name,
                    arguments: StudioModelHTTP.arguments(fromJSONText: block.input)
                )
            }
            return .init(text: text, toolCalls: calls, inputTokens: inputTokens, outputTokens: outputTokens)
        }
    }

    func respond(
        system: String,
        messages: [StudioAgentMessage],
        tools: [StudioAgentToolSpec],
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> StudioAgentTurn {
        var body: [String: StudioJSON] = [
            "model": .string(http.provider.model),
            "system": .string(system),
            "max_tokens": .int(4096),
            "stream": .bool(true),
            "messages": .array(Self.wire(messages))
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters
                ])
            })
        }
        var state = StreamState()
        for try await line in try await http.stream(path: "v1/messages", body: body) {
            guard let payload = StudioModelHTTP.eventPayload(line),
                  let json = StudioJSON.parse(payload) else { continue }
            if let chunk = try state.apply(json) {
                await onText(chunk)
            }
        }
        return state.turn
    }

    /// Anthropic alternates user and assistant turns and carries tool results as user content, so
    /// consecutive same-role entries merge into one message.
    static func wire(_ messages: [StudioAgentMessage]) -> [StudioJSON] {
        var merged: [(role: String, content: [StudioJSON])] = []
        func append(_ role: String, _ blocks: [StudioJSON]) {
            guard !blocks.isEmpty else { return }
            if merged.last?.role == role {
                merged[merged.count - 1].content += blocks
            } else {
                merged.append((role, blocks))
            }
        }
        for message in messages {
            switch message {
            case let .user(text):
                append("user", text.isEmpty ? [] : [.object(["type": "text", "text": .string(text)])])
            case let .assistant(text, toolCalls):
                let textBlocks: [StudioJSON] = text.isEmpty ? [] : [.object(["type": "text", "text": .string(text)])]
                let toolBlocks: [StudioJSON] = toolCalls.map { call in
                    .object([
                        "type": "tool_use",
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": .object(call.arguments)
                    ])
                }
                append("assistant", textBlocks + toolBlocks)
            case let .toolResult(callId, _, content, isError):
                append("user", [.object([
                    "type": "tool_result",
                    "tool_use_id": .string(callId),
                    "content": .string(content),
                    "is_error": .bool(isError)
                ])])
            }
        }
        return merged.map { .object(["role": .string($0.role), "content": .array($0.content)]) }
    }
}

/// Ollama `/api/chat` with tool calling, streamed as newline-delimited JSON. Ollama sends each tool
/// call complete and without an id, so ids are generated here.
struct OllamaAgentModel: StudioAgentModel {
    let http: StudioModelHTTP

    func respond(
        system: String,
        messages: [StudioAgentMessage],
        tools: [StudioAgentToolSpec],
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> StudioAgentTurn {
        var body: [String: StudioJSON] = [
            "model": .string(http.provider.model),
            "stream": .bool(true),
            "messages": .array([.object(["role": "system", "content": .string(system)])] + messages.map(Self.wire))
        ]
        if !tools.isEmpty {
            body["tools"] = .array(tools.map(OpenAICompatibleAgentModel.wire))
        }
        var text = ""
        var toolCalls: [StudioAgentToolCall] = []
        var inputTokens: Int?
        var outputTokens: Int?
        for try await line in try await http.stream(path: "api/chat", body: body) {
            guard let json = StudioJSON.parse(line) else { continue }
            if let error = StudioModelHTTP.streamedError(json) {
                throw error
            }
            if let content = json["message"]?["content"]?.stringValue, !content.isEmpty {
                text += content
                await onText(content)
            }
            toolCalls += Self.toolCalls(in: json)
            if json["done"] == .bool(true) {
                inputTokens = json["prompt_eval_count"]?.intValue
                outputTokens = json["eval_count"]?.intValue
            }
        }
        return .init(text: text, toolCalls: toolCalls, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// Ollama sends each call complete, with arguments as an object or, from some models, as text.
    static func toolCalls(in json: StudioJSON) -> [StudioAgentToolCall] {
        (json["message"]?["tool_calls"]?.arrayValue ?? []).compactMap { call in
            guard let name = call["function"]?["name"]?.stringValue else { return nil }
            let arguments: [String: StudioJSON] = switch call["function"]?["arguments"] {
            case let .object(fields)?: fields
            case let .string(text)?: StudioModelHTTP.arguments(fromJSONText: text)
            default: [:]
            }
            return .init(id: "ollama-\(UUID().uuidString)", name: name, arguments: arguments)
        }
    }

    static func wire(_ message: StudioAgentMessage) -> StudioJSON {
        switch message {
        case let .user(text):
            return .object(["role": "user", "content": .string(text)])
        case let .assistant(text, toolCalls):
            var fields: [String: StudioJSON] = ["role": "assistant", "content": .string(text)]
            if !toolCalls.isEmpty {
                fields["tool_calls"] = .array(toolCalls.map { call in
                    .object(["function": .object(["name": .string(call.name), "arguments": .object(call.arguments)])])
                })
            }
            return .object(fields)
        case let .toolResult(_, name, content, isError):
            return .object([
                "role": "tool",
                "tool_name": .string(name),
                "content": .string(isError ? "Error: \(content)" : content)
            ])
        }
    }
}
