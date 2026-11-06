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

    /// Whether a rebuilt binary should make an idle server exit. `AMOO_MCP_KEEP_STALE=1` keeps it running.
    static var exitsWhenSuperseded: Bool {
        ProcessInfo.processInfo.environment["AMOO_MCP_KEEP_STALE"] != "1"
    }

    /// Ends a server that runs superseded code once it holds no sessions and has no request in flight.
    /// Rebuilding the binary otherwise leaves every earlier client's server running the old code until
    /// someone finds and stops it. A busy server is never interrupted; the staleness warning covers it.
    func exitOnceSupersededAndIdle(runtime: MCPRequestRuntime, diagnostics: MCPTransportDiagnostics) async {
        guard Self.exitsWhenSuperseded else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: supersededPollInterval)
            guard !Task.isCancelled, buildInfo.replacedBinaryDate() != nil else { continue }
            let sessions = await server.sessionManager?.allSessions().count ?? 0
            guard sessions == 0, await runtime.isIdle else { continue }
            diagnostics.emit("binary_replaced_idle_exit")
            exitWhenSuperseded()
            return
        }
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
