import MCP

public struct MCPStdioServer: Sendable {
    private let server: MCPServer

    public init(server: MCPServer) {
        self.server = server
    }

    public func run() async throws {
        let mcp = Server(
            name: "amoo",
            version: "0.1.0",
            title: "Amoo Mobile Testing",
            instructions: "Use these tools to inspect and control a local iOS simulator or Android emulator through amoo. Prefer accessibility identifiers and labels over coordinates when possible.",
            capabilities: .init(tools: .init(listChanged: false))
        )

        let definitions = server.toolDefinitions()
        await mcp.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: definitions.map { $0.mcpTool() })
        }

        await mcp.withMethodHandler(CallTool.self) { params in
            let arguments = params.arguments?.mapValues { String(describing: $0) } ?? [:]
            let result = await server.execute(toolName: params.name, arguments: arguments)
            return result.mcpResult()
        }

        try await mcp.start(transport: StdioTransport())
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3_600))
        }
    }
}
