// SwiftFormat compact calls conflict with SwiftLint argument layout.
// swiftlint:disable multiline_arguments
import AmooCore

public extension CompanionClient {
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
        AccessibilityInspection(status: "unsupported", provider: "companion", limitations: ["Unsupported companion"])
    }
}

// swiftlint:enable multiline_arguments
