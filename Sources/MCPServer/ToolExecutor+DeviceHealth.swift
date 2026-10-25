import AmooCore
import MCP

extension DriverToolExecutor {
    func executeDeviceHealth(driver: any PlatformDriver, arguments: [String: String]) async throws -> ToolResult {
        let health = await driver.connectivityHealth()
        var fields = try Value(health).objectValue ?? [:]
        fields["failure_scope"] = .string(health.failureScope)
        fields["executionStatus"] = .string("succeeded")
        fields["verdict"] = .string("notAssessed")
        fields["render_readiness"] = .string("unverified")
        fields["semantic_readiness"] = .string("unverified")
        if let appID = arguments["app_id"] {
            let deadline = ContinuousClock.now + .seconds(3)
            do {
                let current = try await OperationDeadline.read(until: deadline) { try await driver.currentApp() }
                fields["foreground_app"] = .string(current.bundleID)
                fields["foreground_matches"] = .bool(current.bundleID == appID)
                if current.bundleID == appID {
                    let hierarchy = try await OperationDeadline.read(until: deadline) {
                        try await driver.getViewHierarchy(appID: appID)
                    }
                    fields["semantic_readiness"] = .string(hierarchy.children.isEmpty ? "empty" : "observed")
                }
            } catch {
                fields["readiness_error"] = .string(String(describing: error))
            }
        }
        return .success(
            "Device transport: \(health.deviceTransport.status); companion RPC: \(health.companionRPC.status)."
                + " Failure scope: \(health.failureScope). App/render readiness is reported separately.",
            structuredContent: .object(fields)
        )
    }
}
