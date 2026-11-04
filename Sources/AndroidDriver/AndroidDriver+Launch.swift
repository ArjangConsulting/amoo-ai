// swiftlint:disable multiline_arguments
import AmooCore

public extension AndroidDriver {
    func inspectionCapabilities() async -> InspectionCapabilities {
        InspectionCapabilities(platform: .android, provider: "android.\(inspectionMode.rawValue)")
    }

    func launchAppWithReceipt(
        appID: String, arguments: [String], environment: [String: String]
    ) async throws -> AppLaunchReceipt {
        try await launchApp(appID: appID, arguments: arguments, environment: environment)
        return AppLaunchReceipt(
            appID: appID, freshProcess: true,
            environmentDelivery: environment.isEmpty ? "not_requested" : "intent_extras",
            environmentKeys: Array(environment.keys)
        )
    }
}

// swiftlint:enable multiline_arguments
