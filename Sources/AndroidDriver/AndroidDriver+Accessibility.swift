import AmooCore

public extension AndroidDriver {
    func connectivityHealth() async -> ConnectivityHealth {
        let adb = adb
        let serialArguments = adbArgs()
        let companion = companion
        async let device = ConnectivityHealth.probe(source: "adb get-state") {
            let result = try await adb.run(serialArguments + ["get-state"], timeoutSeconds: 2)
            guard result.exitCode == 0, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "device" else {
                throw AmooError.deviceNotFound("ADB did not report a connected device")
            }
        }
        async let rpc = ConnectivityHealth.probe(source: "companion capabilities RPC") {
            _ = try await companion.getCapabilities()
        }
        return await ConnectivityHealth(deviceTransport: device, companionRPC: rpc)
    }

    func inspectAccessibility(
        appID: String, operation: String, categories: [String], steps: Int, direction: String
    ) async throws -> AccessibilityInspection {
        guard operation == "nativeAudit" else {
            return AccessibilityInspection(
                status: "unsupported",
                provider: "android",
                error: "Use test_talkback on Android"
            )
        }
        try AccessibilityInspectionOptions.validate(
            operation: operation, categories: categories, steps: steps, direction: direction
        )
        return try await companion.inspectAccessibility(
            appID: appID, operation: operation, categories: categories, steps: steps, direction: direction
        )
    }

    func inspectTalkBack(
        appID: String,
        steps: Int,
        direction: String,
        activate: Bool,
        speechExpectations: [AccessibilitySpeechExpectation]
    ) async throws
        -> AccessibilityInspection {
        try await companion.inspectTalkBack(
            appID: appID, steps: steps, direction: direction, activate: activate, speechExpectations: speechExpectations
        )
    }
}
