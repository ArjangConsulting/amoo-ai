// swiftlint:disable multiline_arguments
/// Validation is shared by CLI/MCP and drivers so invalid requests cannot change settings.
public enum AccessibilityInspectionOptions {
    public static let auditCategories: Set<String> = [
        "contrast", "elementDetection", "hitRegion", "sufficientElementDescription",
        "dynamicType", "textClipped", "trait"
    ]

    public static func validate(operation: String, categories: [String], steps: Int, direction: String) throws {
        guard ["nativeAudit", "voiceOver"].contains(operation) else {
            throw AmooError.commandFailed(command: "accessibility inspection", output: "Unknown operation")
        }
        guard (1 ... 30).contains(steps), ["forward", "backward"].contains(direction) else {
            throw AmooError.commandFailed(
                command: "accessibility inspection",
                output: "Requires 1...30 steps and forward/backward direction"
            )
        }
        guard operation != "nativeAudit" || (!categories.isEmpty && Set(categories).isSubset(of: auditCategories))
        else {
            throw AmooError.commandFailed(
                command: "accessibility inspection",
                output: "Requires supported, nonempty audit categories"
            )
        }
    }
}

public extension AccessibilityProvider {
    func inspectAccessibilityJourney(
        appID _: String,
        journey: AccessibilityJourney
    ) async throws -> AccessibilityInspection {
        try journey.validate()
        let reasons = Dictionary(uniqueKeysWithValues: journey.requestedChecks.map { ($0, "Unsupported provider") })
        return AccessibilityInspection(
            status: "unsupported", provider: "authoredAccessibilityJourney",
            error: "Authored journeys require a capable iOS 27 companion.",
            requestedChecks: journey.requestedChecks,
            notEvaluatedReasons: reasons
        )
    }

    func inspectVoiceOver(appID _: String, phases: [VoiceOverPhase]) async throws -> AccessibilityInspection {
        try VoiceOverPhase.validate(phases)
        return AccessibilityInspection(
            status: "unsupported", provider: "platform",
            limitations: ["Multi-phase VoiceOver requires a rebuilt, capable iOS companion."]
        )
    }

    func inspectAccessibility(
        appID _: String, operation _: String, categories _: [String], steps _: Int, direction _: String
    ) async throws -> AccessibilityInspection {
        AccessibilityInspection(
            status: "unsupported", provider: "platform",
            limitations: ["This driver does not implement native accessibility inspection."]
        )
    }
}

// swiftlint:enable multiline_arguments
