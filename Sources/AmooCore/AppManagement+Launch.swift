/// A launch operation that states whether it guarantees a fresh process.
public protocol AppLaunchReporting: Sendable {
    func launchAppWithReceipt(
        appID: String, arguments: [String], environment: [String: String]
    ) async throws -> AppLaunchReceipt
}

/// Provider assertion promises, available without reading device state.
public protocol InspectionCapabilityProviding: Sendable {
    func inspectionCapabilities() async -> InspectionCapabilities
}

public extension AppManagement {
    /// Providers that cannot guarantee a new process must report unknown delivery.
    func launchAppWithReceipt(
        appID: String, arguments: [String], environment: [String: String]
    ) async throws -> AppLaunchReceipt {
        try await launchApp(appID: appID, arguments: arguments, environment: environment)
        return AppLaunchReceipt(
            appID: appID, freshProcess: nil, environmentDelivery: "unknown", environmentKeys: Array(environment.keys)
        )
    }
}

public extension PlatformDriver {
    func inspectionCapabilities() async -> InspectionCapabilities {
        InspectionCapabilities()
    }
}
