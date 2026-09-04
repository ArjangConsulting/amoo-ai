import AmooCore
import AuditEngine
import GRPCService
import TestSession

public struct MCPServer: Sendable {
    private let deviceService: DeviceService
    private let executor: (any ToolExecutor)?
    public let sessionManager: SessionManager?

    public init(
        deviceService: DeviceService = .init(),
        executor: (any ToolExecutor)? = nil,
        sessionManager: SessionManager? = nil
    ) {
        self.deviceService = deviceService
        self.executor = executor
        self.sessionManager = sessionManager
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
        // All driver-routed tools advertise an optional session_id so MCP
        // clients that honor schema (additionalProperties: false) can route
        // calls to a specific session created by start_session.
        let driverRouted = (
            DeviceTools.definitions
                + ActionTools.definitions
                + QueryTools.definitions
                + AuditTools.definitions
                + AssistantTools.definitions
        ).map { $0.allowingSessionID() }

        return driverRouted + SessionTools.definitions + CompanionTools.definitions + IntentTools.definitions
    }
}

extension ToolDefinition {
    /// Returns a copy of the definition with `session_id` added as an optional
    /// property. Driver-routed tools opt in to this so AI clients can scope
    /// calls to a session created by `start_session`.
    func allowingSessionID() -> ToolDefinition {
        guard properties["session_id"] == nil else { return self }
        var copy = self
        copy.properties["session_id"] = ToolInputProperty(
            type: "string",
            description: "Optional session id; routes this call to that session's driver"
                + " and records it in the session's action history"
        )
        return copy
    }
}
