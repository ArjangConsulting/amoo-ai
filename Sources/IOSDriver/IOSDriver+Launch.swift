// swiftlint:disable multiline_arguments
import AmooCore

public extension IOSDriver {
    func inspectionCapabilities() async -> InspectionCapabilities {
        InspectionCapabilities(platform: .ios, provider: "xctest")
    }

    func launchAppWithReceipt(
        appID: String, arguments: [String], environment: [String: String]
    ) async throws -> AppLaunchReceipt {
        try await launchApp(appID: appID, arguments: arguments, environment: environment)
        return AppLaunchReceipt(
            appID: appID, freshProcess: true,
            environmentDelivery: environment.isEmpty ? "not_requested" : "process_environment",
            environmentKeys: Array(environment.keys)
        )
    }
}

// swiftlint:enable multiline_arguments
