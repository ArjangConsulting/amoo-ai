import AmooTelemetry
import Foundation
import MCP
import Tracing

/// What a request span needs to know about one JSON-RPC request.
struct MCPRequestTraceInfo: Sendable {
    let method: String
    let toolName: String
    let id: Value
    let params: [String: Value]?
}

extension MCPStdioServer {
    /// Runs one JSON-RPC request inside an OpenTelemetry server span named per the MCP semantic
    /// conventions (`tools/call take_screenshot`, `tools/list`). A W3C `traceparent` in `_meta`
    /// makes the span a child of the client's trace.
    static func traced(
        _ request: MCPRequestTraceInfo,
        clientName: String?,
        operation: @Sendable () async -> Data?
    ) async -> Data? {
        let method = request.method
        let toolName = request.toolName
        let id = request.id
        var context = InstrumentationContext.current ?? .topLevel
        let meta = request.params?["_meta"]?.objectValue ?? [:]
        InstrumentationSystem.instrument.extract(
            meta.compactMapValues(\.stringValue), into: &context, using: DictionaryCarrier()
        )
        let client = clientName ?? meta["io.modelcontextprotocol/clientInfo"]?.objectValue?["name"]?.stringValue
        let name = toolName.isEmpty ? method : "\(method) \(toolName)"
        return await withSpan(name, context: context, ofKind: .server) { span in
            span.attributes[TelemetryAttribute.mcpMethodName] = method
            span.attributes[TelemetryAttribute.networkTransport] = "pipe"
            span.attributes[TelemetryAttribute.jsonRPCRequestID] = id.description
            if !toolName.isEmpty {
                span.attributes[TelemetryAttribute.genAIToolName] = toolName
                span.attributes[TelemetryAttribute.genAIOperationName] = "execute_tool"
            }
            if let version = meta["io.modelcontextprotocol/protocolVersion"]?.stringValue {
                span.attributes[TelemetryAttribute.mcpProtocolVersion] = version
            }
            if let client {
                span.attributes[TelemetryAttribute.clientName] = client
            }
            return await TelemetryCallContext.$current.withValue(
                TelemetryCallContext(surface: "mcp", clientName: client)
            ) {
                await operation()
            }
        }
    }
}
