import AmooCore
import Foundation
import MCP

extension MCPStdioServer {
    /// Prefixes a staleness warning when the binary on disk was rebuilt after this server started,
    /// so a caller hitting an already-fixed bug learns to restart instead of debugging old code.
    static func annotatingStaleness(_ result: ToolResult, buildInfo: AmooBuildInfo) -> ToolResult {
        guard let warning = buildInfo.stalenessWarning() else { return result }
        var annotated = result
        let recovery = "Using the selected amoo binary, check `doctor --mcp-pid \(buildInfo.pid) --json`. "
            + "End reachable sessions and reconnect this client's MCP server. If it cannot stop this stale server, "
            + "use `doctor --mcp-pid \(buildInfo.pid) --kill-stale --json`, then reconnect and recheck the new PID. "
            + "Leave unrelated clients running. After releasing ownership, supported CLI work can use "
            + "`doctor --cli-only --json`; MCP-only requirements need reconnecting. Never reuse old session IDs."
        annotated.content = warning + "\n" + recovery + "\n\n" + result.content
        return annotated
    }

    /// Build identity under `_meta`, so a client can tell which code a long-lived server runs.
    var buildMeta: Value {
        let format = ISO8601DateFormatter()
        let stale = buildInfo.replacedBinaryDate() != nil
        var fields: [String: Value] = [
            "version": .string(buildInfo.version),
            "pid": .int(Int(buildInfo.pid)),
            "started_at": .string(format.string(from: buildInfo.startedAt)),
            "stale": .bool(stale),
            "doctor_arguments": .array(["doctor", "--mcp-pid", String(buildInfo.pid), "--json"].map(Value.string))
        ]
        if stale {
            fields["stale_cleanup_arguments"] = .array(
                ["doctor", "--mcp-pid", String(buildInfo.pid), "--kill-stale", "--json"].map(Value.string)
            )
        }
        fields["commit"] = buildInfo.sourceCommit.map(Value.string)
        fields["binary_sha256"] = buildInfo.binarySHA256.map(Value.string)
        fields["source_fingerprint"] = buildInfo.sourceFingerprint.map(Value.string)
        fields["source_dirty"] = buildInfo.sourceDirty.map(Value.string)
        fields["binary_path"] = buildInfo.executablePath.map(Value.string)
        fields["binary_modified_at"] = buildInfo.binaryModifiedAt.map { .string(format.string(from: $0)) }
        return .object(fields)
    }

    func modernToolResult(_ result: ToolResult) -> Value {
        var fields = toolResultFields(result)
        fields["resultType"] = .string("complete")
        fields["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfo, "dev.amoo/build": buildMeta])
        return .object(fields)
    }

    func legacyToolResult(_ result: ToolResult) -> Value {
        var fields = toolResultFields(result)
        fields["_meta"] = .object(["dev.amoo/build": buildMeta])
        return .object(fields)
    }

    func toolResultFields(_ result: ToolResult) -> [String: Value] {
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
}
