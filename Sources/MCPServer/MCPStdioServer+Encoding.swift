import AmooCore
import Foundation
import MCP

extension MCPStdioServer {
    var encodedTools: Value {
        let tools = server.toolDefinitions()
            .sorted { $0.name < $1.name }
            .compactMap { try? Value($0.mcpTool()) }
        return .array(tools)
    }

    var serverCapabilities: Value {
        .object(["tools": .object(["listChanged": .bool(false)])])
    }

    var serverInfo: Value {
        .object([
            "name": .string("amoo"),
            "version": .string(AmooVersion.current),
            "title": .string("Amoo Mobile Testing")
        ])
    }

    func withModernResultFields(_ fields: [String: Value]) -> Value {
        var result = fields
        result["resultType"] = .string("complete")
        result["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfo, "dev.amoo/build": buildMeta])
        return .object(result)
    }

    func unsupportedVersion(id: Value, requested: String) -> WireResponse {
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

    func encoded(_ response: WireResponse) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data: Data
        do { data = try encoder.encode(response) } catch {
            // Keep the request ID so a nonfinite backend value cannot silently strand the caller.
            data = (try? encoder.encode(WireResponse.failure(
                id: response.id, code: -32603, message: "Response contains an invalid value"
            ))) ??
                Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Encoding failed\"}}"
                    .utf8)
        }
        data.append(0x0A)
        return data
    }
}
