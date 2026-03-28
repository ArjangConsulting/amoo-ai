import AuditEngine
import GRPCService
import MobileTestingCore

public struct MCPServer: Sendable {
    private let deviceService: DeviceService
    private let executor: (any ToolExecutor)?

    public init(deviceService: DeviceService = .init(), executor: (any ToolExecutor)? = nil) {
        self.deviceService = deviceService
        self.executor = executor
    }

    public func toolNames() -> [String] {
        allDefinitions.map(\.name)
    }

    public func toolDefinitions() -> [ToolDefinition] {
        allDefinitions
    }

    public func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
        guard let executor else {
            return .error("No tool executor configured. Connect a device driver first.")
        }
        return await executor.execute(toolName: toolName, arguments: arguments)
    }

    public func health() -> String {
        deviceService.health()
    }

    private var allDefinitions: [ToolDefinition] {
        DeviceTools.definitions + ActionTools.definitions + QueryTools.definitions + AuditTools.definitions + AITools
            .definitions
    }
}
