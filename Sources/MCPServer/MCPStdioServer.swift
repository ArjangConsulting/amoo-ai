import AmooCore
import Foundation
import MCP

public struct MCPStdioServer: Sendable {
    static let modernProtocolVersion = "2026-07-28"
    static let legacyProtocolVersions = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05"
    ]

    /// Sent verbatim in every `initialize` / `server/discover` response and cached by clients, so
    /// keep it self-contained. `MCPInstructionsAlignmentTests` pins the points a caller must be able
    /// to rely on when it records a session for `compile_session_to_plan` + `amoo generate test`.
    static let instructions = """
    Use these tools to inspect and drive a booted iOS simulator or Android emulator through amoo, \
    and — when recording a session for `amoo generate test` — to produce a plan that generates a \
    readable, complete XCUITest/Espresso test.

    Canonical workflow: `start_session` -> drive the app under test -> `end_session` (this \
    already compiles the recorded history and writes `plan.json`) -> inspect the plan and its \
    warnings -> `amoo generate test`. `compile_session_to_plan` is an optional preview of the \
    plan you may call while the session is still open; it is never a required step and running \
    it does not change the final plan `end_session` writes.

    `start_session` is the one entrypoint: it boots the device, ensures the companion is built \
    and running, installs the build, and launches the app — there is no separate companion-start \
    call. Thread the returned `session_id` through every later tool call. If you want the \
    one-time companion build off the critical path, call `companion_warm` first and poll \
    `companion_status`. Pass `device_hint` to `device_boot` when more than one device is \
    attached. `webview_eval` / `webview_dom` reach state inside a WKWebView/WebView that the \
    accessibility snapshot cannot see.

    A passing session is not the goal; a good generated test is. That means:

    1. Deterministic launch state. If the caller supplies launch arguments or environment (a \
    skip-onboarding flag, a reset-state flag, a mock-server URL), start the session with them so \
    the plan records them and the generated test reproduces them in setUp. Do not tap through \
    onboarding you were given a flag to skip.

    2. Resolve elements semantically before you act. Use `describe_screen` to orient on an \
    unfamiliar screen and `find_elements` to confirm a specific target, then act through \
    `tap_element` / `set_text` / `swipe_in_direction`. Prefer a stable accessibility id, then a \
    visible label, then a text filter — and any of those over raw coordinates.

    3. List-row gestures — one canonical workflow. To tap or swipe one row of a list (SwiftUI \
    `.swipeActions`, per-row buttons): call `find_elements` for that row, then call \
    `swipe_in_direction` with the row's `element_id` (preferred) or `element_label`. That is the \
    reliable path — the companion fails rather than guessing when the id/label is ambiguous, and \
    the recorded step keeps the row's identity, so the compiler emits an element-scoped gesture \
    such as `groceriesTaskRow.swipeLeft()`. Only if the row has no stable id or label, fall \
    back to a coordinate `swipe`: the recorder then binds it to the element you just resolved. \
    Never read coordinates off a screenshot — screenshots are pixels, gestures are points.

    4. Verify every mutation with an explicit semantic assertion. After a delete, call \
    `assert_absent` (or `find_elements` and check the count) on a text/label — not a \
    screenshot. After an add, `assert_visible` the new element. These become the test's \
    assertions; an unverified mutation compiles to an action with nothing checking it.

    5. End the session, then inspect the plan before generating. `end_session` already compiles \
    the recorded history and writes `plan.json`; you do not call `compile_session_to_plan` as a \
    follow-up step. Read `plan.json` and every `compiledPlan.warnings` entry. An `excluded` / \
    incomplete-plan warning means a required app-under-test action was dropped: that is a FAILED \
    codegen result, not a finished test. Fix the recording — add an accessibility identifier, \
    drive through an addressable ancestor, re-record — rather than passing `--allow-incomplete`. \
    If you pass it anyway, report which steps are missing and why. amoo's own lifecycle calls \
    (`start_session`, `end_session`, `compile_session_to_plan`, `get_session_report`) are never \
    recorded as app actions and never produce an `XCTFail` for uncompiled work.

    6. Review the generated code. Local variable names come from labels and inferred roles, never \
    from UUIDs, hashes, or record ids; a UUID/hash-derived name or an \
    `XCTFail("Uncompiled required action …")` means the plan was incomplete. Give the test a \
    descriptive name from the flow the caller asked for (`amoo generate test --test-name`).

    7. Report back the plan path, the generated file path, every compiled-plan warning, and any \
    limitation (mock server required, transient system-UI steps, approximate selectors).
    """
    private static let cacheTTLMilliseconds = 3_600_000

    private let server: MCPServer

    public init(server: MCPServer) {
        self.server = server
    }

    public func run() async throws {
        var buffer = Data()
        var legacyInitialized = false

        while true {
            let chunk = FileHandle.standardInput.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                var line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                guard !line.isEmpty else { continue }

                let outcome = await handle(Data(line), legacyInitialized: legacyInitialized)
                legacyInitialized = legacyInitialized || outcome.initializedLegacy
                if let response = outcome.response {
                    try write(response)
                }
            }
        }

        if !buffer.isEmpty {
            let outcome = await handle(buffer, legacyInitialized: legacyInitialized)
            if let response = outcome.response {
                try write(response)
            }
        }
    }

    private func handle(_ data: Data, legacyInitialized: Bool) async -> HandlingOutcome {
        let request: WireRequest
        do {
            request = try JSONDecoder().decode(WireRequest.self, from: data)
        } catch {
            return .response(.failure(id: .null, code: -32700, message: "Parse error"))
        }

        guard request.jsonrpc == "2.0" else {
            return .response(.failure(id: request.id ?? .null, code: -32600, message: "Invalid Request"))
        }

        if request.method == "notifications/initialized" || request.method == "notifications/cancelled" {
            return .none
        }

        guard let id = request.id else {
            return .none
        }

        if request.method == "initialize" {
            return handleLegacyInitialize(request, id: id)
        }

        let params = request.params?.objectValue ?? [:]
        if let metadata = params["_meta"]?.objectValue,
           let requestedVersion = metadata["io.modelcontextprotocol/protocolVersion"]?.stringValue {
            guard requestedVersion == Self.modernProtocolVersion else {
                return .response(unsupportedVersion(id: id, requested: requestedVersion))
            }
            guard metadata["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil else {
                return .response(.failure(
                    id: id,
                    code: -32602,
                    message: "Modern MCP requests require _meta.io.modelcontextprotocol/clientCapabilities"
                ))
            }
            return await .response(handleModernRequest(request, id: id, params: params))
        }

        guard legacyInitialized else {
            return .response(.failure(
                id: id,
                code: -32602,
                message: "Request must include MCP 2026-07-28 per-request _meta or begin with initialize"
            ))
        }
        return await .response(handleLegacyRequest(request, id: id, params: params))
    }

    private func handleLegacyInitialize(_ request: WireRequest, id: Value) -> HandlingOutcome {
        let params = request.params?.objectValue ?? [:]
        let requested = params["protocolVersion"]?.stringValue ?? Self.legacyProtocolVersions[0]
        let negotiated = Self.legacyProtocolVersions.contains(requested)
            ? requested
            : Self.legacyProtocolVersions[0]

        return .legacyInitialization(.success(id: id, result: .object([
            "protocolVersion": .string(negotiated),
            "capabilities": serverCapabilities,
            "serverInfo": serverInfo,
            "instructions": .string(Self.instructions)
        ])))
    }

    private func handleModernRequest(
        _ request: WireRequest,
        id: Value,
        params: [String: Value]
    ) async -> WireResponse {
        switch request.method {
        case "server/discover":
            return .success(id: id, result: withModernResultFields([
                "supportedVersions": .array(
                    ([Self.modernProtocolVersion] + Self.legacyProtocolVersions).map(Value.string)
                ),
                "capabilities": serverCapabilities,
                "instructions": .string(Self.instructions),
                "ttlMs": .int(Self.cacheTTLMilliseconds),
                "cacheScope": .string("public")
            ]))

        case "tools/list":
            return .success(id: id, result: withModernResultFields([
                "tools": encodedTools,
                "ttlMs": .int(Self.cacheTTLMilliseconds),
                "cacheScope": .string("public")
            ]))

        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .failure(id: id, code: -32602, message: "tools/call requires a string name")
            }
            guard server.toolNames().contains(name) else {
                return .failure(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            guard params["arguments"] == nil || params["arguments"]?.objectValue != nil else {
                return .failure(id: id, code: -32602, message: "tools/call arguments must be an object")
            }

            let arguments = params["arguments"]?.objectValue?.mapValues(stringifyArgumentValue) ?? [:]
            let result = await server.execute(toolName: name, arguments: arguments)
            return .success(id: id, result: modernToolResult(result))

        default:
            return .failure(id: id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    private func handleLegacyRequest(
        _ request: WireRequest,
        id: Value,
        params: [String: Value]
    ) async -> WireResponse {
        switch request.method {
        case "ping":
            return .success(id: id, result: .object([:]))

        case "tools/list":
            return .success(id: id, result: .object(["tools": encodedTools]))

        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return .failure(id: id, code: -32602, message: "tools/call requires a string name")
            }
            guard params["arguments"] == nil || params["arguments"]?.objectValue != nil else {
                return .failure(id: id, code: -32602, message: "tools/call arguments must be an object")
            }

            let arguments = params["arguments"]?.objectValue?.mapValues(stringifyArgumentValue) ?? [:]
            let result = await server.execute(toolName: name, arguments: arguments)
            return .success(id: id, result: legacyToolResult(result))

        default:
            return .failure(id: id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    private var encodedTools: Value {
        let tools = server.toolDefinitions()
            .sorted { $0.name < $1.name }
            .compactMap { try? Value($0.mcpTool()) }
        return .array(tools)
    }

    private var serverCapabilities: Value {
        .object(["tools": .object(["listChanged": .bool(false)])])
    }

    private var serverInfo: Value {
        .object([
            "name": .string("amoo"),
            "version": .string(AmooVersion.current),
            "title": .string("Amoo Mobile Testing")
        ])
    }

    private func withModernResultFields(_ fields: [String: Value]) -> Value {
        var result = fields
        result["resultType"] = .string("complete")
        result["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfo])
        return .object(result)
    }

    private func modernToolResult(_ result: ToolResult) -> Value {
        var fields = toolResultFields(result)
        fields["resultType"] = .string("complete")
        fields["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfo])
        return .object(fields)
    }

    private func legacyToolResult(_ result: ToolResult) -> Value {
        .object(toolResultFields(result))
    }

    private func toolResultFields(_ result: ToolResult) -> [String: Value] {
        var content: [Value] = [
            .object([
                "type": .string("text"),
                "text": .string(result.content)
            ])
        ]
        if let image = result.image {
            content.append(.object([
                "type": .string("image"),
                "data": .string(image.data.base64EncodedString()),
                "mimeType": .string(image.mimeType)
            ]))
        }

        var fields: [String: Value] = [
            "content": .array(content),
            "isError": .bool(result.isError)
        ]
        fields["structuredContent"] = result.structuredContent
        return fields
    }

    private func unsupportedVersion(id: Value, requested: String) -> WireResponse {
        .failure(
            id: id,
            code: -32022,
            message: "Unsupported protocol version",
            data: .object([
                "supported": .array(
                    ([Self.modernProtocolVersion] + Self.legacyProtocolVersions).map(Value.string)
                ),
                "requested": .string(requested)
            ])
        )
    }

    private func write(_ response: WireResponse) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(response)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

private struct WireRequest: Decodable, Sendable {
    let jsonrpc: String
    let id: Value?
    let method: String
    let params: Value?
}

private struct WireResponse: Encodable, Sendable {
    let jsonrpc = "2.0"
    let id: Value
    let result: Value?
    let error: Value?

    static func success(id: Value, result: Value) -> Self {
        Self(id: id, result: result, error: nil)
    }

    static func failure(
        id: Value,
        code: Int,
        message: String,
        data: Value? = nil
    ) -> Self {
        var error: [String: Value] = [
            "code": .int(code),
            "message": .string(message)
        ]
        error["data"] = data
        return Self(id: id, result: nil, error: .object(error))
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

private struct HandlingOutcome: Sendable {
    var response: WireResponse?
    var initializedLegacy: Bool

    static let none = Self(response: nil, initializedLegacy: false)

    static func response(_ response: WireResponse) -> Self {
        Self(response: response, initializedLegacy: false)
    }

    static func legacyInitialization(_ response: WireResponse) -> Self {
        Self(response: response, initializedLegacy: true)
    }
}

func stringifyArgumentValue(_ value: Value) -> String {
    switch value {
    case .null:
        return ""
    case let .bool(bool):
        return bool ? "true" : "false"
    case let .int(int):
        return String(int)
    case let .double(double):
        return String(double)
    case let .string(string):
        return string
    case .array, .object, .data:
        guard
            let data = try? JSONEncoder().encode(value),
            let json = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return json
    }
}
