import AmooCore
import MCP

extension DriverToolExecutor {
    func diagnoseConnectivityFailure(_ result: ToolResult, arguments: [String: String]) async -> ToolResult {
        guard result.isError else { return result }
        let text = result.content.lowercased()
        guard text.contains("timed out") || text.contains("timedout") || text.contains("timeout(") || text
            .contains("deadlineexceeded") ||
            text.contains("deadline exceeded") || text.contains("connection refused") ||
            text.contains("could not establish a connection"),
            let driver = try? await resolveDriver(arguments: arguments) else { return result }
        let health = await driver.connectivityHealth()
        guard !["unknown", "none"].contains(health.failureScope) else { return result }
        var fields = result.structuredContent?.objectValue ?? [:]
        fields["companion_health"] = .string(health.companionRPC.status)
        fields["device_health"] = .string(health.deviceTransport.status)
        fields["failure_scope"] = .string(health.failureScope)
        fields["health_evidence"] = try? Value(health)
        if let execution = health.deviceExecution {
            fields["device_execution_health"] = .string(execution.status)
        }
        let recovery = health.failureScope == "device_execution"
            ? " Android command execution is unresponsive. Use device_shutdown and wait for verified exit"
            + " before restarting the AVD."
            : ""
        return ToolResult(
            content: result.content + "\nFailure scope: \(health.failureScope)." + recovery,
            isError: true,
            structuredContent: .object(fields)
        )
    }
}
