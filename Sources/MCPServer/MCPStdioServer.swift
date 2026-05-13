import Foundation
import MCP
import MobileTestingCore

public struct MCPStdioServer: Sendable {
    private let server: MCPServer

    public init(server: MCPServer) {
        self.server = server
    }

    public func run() async throws {
        let mcp = Server(
            name: "amoo",
            version: AmooVersion.current,
            title: "Amoo Mobile Testing",
            instructions: "Use these tools to inspect and control a local iOS simulator or Android emulator through amoo. Prefer accessibility identifiers and labels over coordinates when possible.",
            capabilities: .init(tools: .init(listChanged: false))
        )

        let definitions = server.toolDefinitions()
        await mcp.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: definitions.map { $0.mcpTool() })
        }

        await mcp.withMethodHandler(CallTool.self) { params in
            let arguments = params.arguments?.mapValues(stringifyArgumentValue) ?? [:]
            let result = await server.execute(toolName: params.name, arguments: arguments)
            return result.mcpResult()
        }

        try await mcp.start(transport: StdioTransport())
        await mcp.waitUntilCompleted()
        await mcp.stop()
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
