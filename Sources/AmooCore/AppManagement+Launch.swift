import Foundation

/// The `environment` tool argument shared by live launches and recorded plans.
public enum AppLaunchEnvironment {
    public static func parse(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        let separator: Character = raw.contains("\n") ? "\n" : ","
        var result: [String: String] = [:]
        for pair in raw.split(separator: separator) {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            if let equals = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    result[key] = String(trimmed[trimmed.index(after: equals)...])
                }
            }
        }
        return result
    }
}

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
            appID: appID,
            freshProcess: nil,
            environmentDelivery: "unknown",
            environmentKeys: Array(environment.keys),
            argumentsDelivery: "unknown",
            argumentCount: arguments.count
        )
    }
}

public extension PlatformDriver {
    func inspectionCapabilities() async -> InspectionCapabilities {
        InspectionCapabilities()
    }
}
