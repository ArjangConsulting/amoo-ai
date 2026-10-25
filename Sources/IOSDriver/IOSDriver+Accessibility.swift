import AmooCore

public extension IOSDriver {
    func connectivityHealth() async -> ConnectivityHealth {
        let companion = companion
        let rpc = await ConnectivityHealth.probe(source: "companion capabilities RPC") {
            _ = try await companion.getCapabilities()
        }
        return ConnectivityHealth(
            deviceTransport: .init(source: "Independent iOS transport probe unavailable"), companionRPC: rpc
        )
    }

    func inspectAccessibilityJourney(
        appID: String,
        journey: AccessibilityJourney
    ) async throws -> AccessibilityInspection {
        try journey.validate()
        return try await companion.inspectAccessibilityJourney(appID: appID, journey: journey)
    }

    func inspectVoiceOver(appID: String, phases: [VoiceOverPhase]) async throws -> AccessibilityInspection {
        try VoiceOverPhase.validate(phases)
        return try await companion.inspectVoiceOver(appID: appID, phases: phases)
    }

    func inspectAccessibility(
        appID: String, operation: String, categories: [String], steps: Int, direction: String
    ) async throws -> AccessibilityInspection {
        try AccessibilityInspectionOptions.validate(
            operation: operation, categories: categories, steps: steps, direction: direction
        )
        return try await companion.inspectAccessibility(
            appID: appID, operation: operation, categories: categories, steps: steps, direction: direction
        )
    }
}
