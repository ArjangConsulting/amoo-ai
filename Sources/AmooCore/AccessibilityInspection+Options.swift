// swiftlint:disable multiline_arguments
/// Validation is shared by CLI/MCP and drivers so invalid requests cannot change settings.
public enum AccessibilityInspectionOptions {
    public static let androidAuditCategories: Set<String> = [
        "contrast", "hitRegion", "sufficientElementDescription", "duplicateSpeakableText", "editableContentDescription"
    ]
    public static let iosAuditCategories: Set<String> = [
        "contrast", "elementDetection", "hitRegion", "sufficientElementDescription",
        "dynamicType", "textClipped", "trait"
    ]

    public static let auditCategories = iosAuditCategories.union(androidAuditCategories)

    public static func validateSpeech(_ expectations: [AccessibilitySpeechExpectation], steps: Int) throws {
        guard expectations.count == steps, (1 ... 30).contains(steps), expectations.allSatisfy({
            ($0.equals != nil) != ($0.contains != nil) && $0.elementID == nil
                && ($0.equals ?? $0.contains ?? "").utf8.count <= 8192
        }) else {
            throw AmooError.commandFailed(
                command: "speech assertions",
                output: "Provide one equals/contains expectation per move, with no elementID"
            )
        }
    }

    public static func validate(operation: String, categories: [String], steps: Int, direction: String) throws {
        guard ["nativeAudit", "voiceOver", "talkBack"].contains(operation) else {
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

    func inspectTalkBack(
        appID _: String,
        steps _: Int,
        direction _: String,
        activate _: Bool,
        speechExpectations _: [AccessibilitySpeechExpectation]
    ) async throws
        -> AccessibilityInspection {
        AccessibilityInspection(
            status: "unsupported", provider: "androidTalkBack",
            error: "This provider does not support qualified TalkBack traversal and speech capture."
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
