import AmooCore
import Foundation
import MCP

extension MCPStdioServer {
    /// Prefixes a staleness warning when the binary on disk was rebuilt after this server started,
    /// so a caller hitting an already-fixed bug learns to restart instead of debugging old code.
    static func annotatingStaleness(_ result: ToolResult, buildInfo: AmooBuildInfo) -> ToolResult {
        guard let warning = buildInfo.stalenessWarning() else { return result }
        var annotated = result
        annotated.content = warning + "\n\n" + result.content
        return annotated
    }

    /// Build identity under `_meta`, so a client can tell which code a long-lived server runs.
    var buildMeta: Value {
        let format = ISO8601DateFormatter()
        var fields: [String: Value] = [
            "version": .string(buildInfo.version),
            "pid": .int(Int(buildInfo.pid)),
            "started_at": .string(format.string(from: buildInfo.startedAt)),
            "stale": .bool(buildInfo.replacedBinaryDate() != nil)
        ]
        fields["commit"] = buildInfo.sourceCommit.map(Value.string)
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
        .object(toolResultFields(result))
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
