/// Attribute keys amoo writes on spans. Standard OpenTelemetry semantic conventions are used where
/// they exist (MCP, GenAI tool execution, RPC, errors); amoo-specific measurements use `amoo.*`.
public enum TelemetryAttribute {
    // MCP semantic conventions.
    public static let mcpMethodName = "mcp.method.name"
    public static let mcpSessionID = "mcp.session.id"
    public static let mcpProtocolVersion = "mcp.protocol.version"
    public static let jsonRPCRequestID = "jsonrpc.request.id"
    public static let networkTransport = "network.transport"

    // GenAI tool execution.
    public static let genAIOperationName = "gen_ai.operation.name"
    public static let genAIToolName = "gen_ai.tool.name"
    public static let genAIToolCallID = "gen_ai.tool.call.id"

    // RPC.
    public static let rpcSystem = "rpc.system"
    public static let rpcService = "rpc.service"
    public static let rpcMethod = "rpc.method"
    public static let rpcGRPCStatusCode = "rpc.grpc.status_code"

    // Errors and processes.
    public static let errorType = "error.type"
    public static let processExecutableName = "process.executable.name"
    public static let processExitCode = "process.exit.code"

    // amoo.
    public static let runID = "amoo.run.id"
    public static let sessionID = "amoo.session.id"
    public static let client = "amoo.client"
    public static let clientName = "amoo.client.name"
    public static let platform = "amoo.platform"
    public static let responseMode = "amoo.response.mode"
    public static let responseBytes = "amoo.response.bytes"
    public static let responseTextBytes = "amoo.response.text_bytes"
    public static let imageBytes = "amoo.image.bytes"
    public static let imageWidth = "amoo.image.width"
    public static let imageHeight = "amoo.image.height"
    public static let imageInline = "amoo.image.inline"
    public static let imageScale = "amoo.image.scale"
    public static let evidenceBytes = "amoo.evidence.bytes"
    public static let observedElements = "amoo.elements.observed"
    public static let repeatedCall = "amoo.call.repeated"
    public static let intent = "amoo.call.intent"
    public static let companionServerMilliseconds = "amoo.companion.server_ms"
    public static let settleFrames = "amoo.screenshot.settle_frames"
    public static let queueWaitMilliseconds = "amoo.queue.wait_ms"
    public static let processSubcommand = "amoo.process.subcommand"
}

/// Which amoo surface is handling the current request, recorded on tool-execution spans.
public struct TelemetryCallContext: Sendable {
    /// `mcp`, `cli` or `flow`.
    public var surface: String
    /// The MCP client's `clientInfo.name`, when known.
    public var clientName: String?

    public init(surface: String, clientName: String? = nil) {
        self.surface = surface
        self.clientName = clientName
    }

    @TaskLocal public static var current: Self?
}

/// Builds low-cardinality span names and attributes from argument vectors.
public enum TelemetryNaming {
    /// Flags whose following argument is a value (serial, device, path), not a subcommand.
    private static let valueFlags: Set<String> = [
        "-s", "-t", "-H", "-P", "-d", "--device", "--udid", "-o", "--output", "--platform", "--app-id"
    ]

    /// Up to `limit` leading subcommand words (`shell input`, `simctl io`, `device tap`). Stops at the
    /// first token that is not a short lowercase word, so values, paths and typed text never appear.
    public static func command(_ arguments: [String], limit: Int = 2) -> String? {
        var tokens: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if argument.hasPrefix("-") {
                skipNext = valueFlags.contains(argument)
                continue
            }
            guard argument.count <= 24, argument.first?.isLetter == true,
                  argument.allSatisfy({ $0.isLowercase || $0 == "-" || $0 == "_" })
            else { break }
            tokens.append(argument)
            if tokens.count == limit {
                break
            }
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }
}
