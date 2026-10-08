import Foundation

// SwiftFormat's compact wrapping conflicts with SwiftLint's one-argument/parameter-per-line rules.
// swiftlint:disable multiline_parameters

/// Evidence from a bounded native audit or screen-reader traversal, not a conformance verdict.
public struct AccessibilityInspection: Codable, Sendable, Equatable {
    public struct Issue: Codable, Sendable, Equatable {
        public var category: String
        public var description: String
        public var details: String
        public var elementID: String?
        public var label: String?

        public init(category: String, description: String, details: String, elementID: String?, label: String?) {
            self.category = category
            self.description = description
            self.details = details
            self.elementID = elementID
            self.label = label
        }
    }

    /// Execution remains distinct from findings and VoiceOver restoration.
    public var executionStatus: String {
        switch status {
        case "pass", "fail", "observed": "succeeded"
        case "unsupported": "unsupported"
        case "executionError": "failed"
        default: "unknown"
        }
    }

    /// Observing speech never evaluates a semantic accessibility assertion.
    public var verdict: String {
        if provider == "authoredAccessibilityJourney" {
            guard let journey, journey.schemaVersion == 1,
                  let specification = journey.specification, (try? specification.validate()) != nil,
                  specification.id == journey.id,
                  requestedChecks == specification.requestedChecks,
                  journey.checks.count == requestedChecks.count,
                  Set(journey.checks.map(\.id)) == Set(requestedChecks) else { return "notAssessed" }
            if journey.checks.contains(where: { $0.outcome == .fail }) {
                return "fail"
            }
            guard status == "observed", !truncated, !requestedChecks.isEmpty,
                  Set(requestedChecks) == Set(evaluatedChecks), notEvaluatedReasons.isEmpty,
                  evaluatedChecks.count == requestedChecks.count,
                  Set(journey.checks.map(\.id)) == Set(requestedChecks),
                  journey.checks.allSatisfy({ $0.outcome == .pass }) else { return "notAssessed" }
            return "pass"
        }
        guard provider == "appleNativeAudit" else { return "notAssessed" }
        if !issues.isEmpty {
            return "fail"
        }
        guard status == "pass", !truncated, !evaluatedChecks.isEmpty,
              Set(requestedChecks) == Set(evaluatedChecks), notEvaluatedReasons.isEmpty else { return "notAssessed" }
        return "pass"
    }

    public var cleanupStatus: String {
        if cleanupError != nil {
            return "failed"
        }
        guard let originalVoiceOverEnabled
        else {
            return ["appleVoiceOver", "authoredAccessibilityJourney"].contains(provider) ? "unknown" : "notRequired"
        }
        guard let restoredVoiceOverEnabled else { return "unknown" }
        return originalVoiceOverEnabled == restoredVoiceOverEnabled ? "restored" : "failed"
    }

    public var journey: AccessibilityJourneyReport?
    public var requestedChecks: [String]
    public var evaluatedChecks: [String]
    public var notEvaluatedReasons: [String: String]
    public var truncated: Bool
    public var cleanupError: String?
    public var phases: [VoiceOverPhaseObservation]
    public var provenance: [String: String]
    public var status: String
    public var provider: String
    public var issues: [Issue]
    public var utterances: [String]
    public var originalVoiceOverEnabled: Bool?
    public var restoredVoiceOverEnabled: Bool?
    public var error: String?
    public var limitations: [String]

    public init(
        status: String, provider: String, issues: [Issue] = [], utterances: [String] = [],
        originalVoiceOverEnabled: Bool? = nil, restoredVoiceOverEnabled: Bool? = nil,
        error: String? = nil, limitations: [String] = [],
        requestedChecks: [String] = [], evaluatedChecks: [String] = [],
        notEvaluatedReasons: [String: String] = [:], truncated: Bool = false, cleanupError: String? = nil,
        phases: [VoiceOverPhaseObservation] = [], provenance: [String: String] = [:],
        journey: AccessibilityJourneyReport? = nil
    ) {
        self.journey = journey
        self.requestedChecks = requestedChecks
        self.evaluatedChecks = evaluatedChecks
        self.notEvaluatedReasons = notEvaluatedReasons
        self.truncated = truncated
        self.cleanupError = cleanupError
        self.phases = phases
        self.provenance = provenance
        self.status = status
        self.provider = provider
        self.issues = issues
        self.utterances = utterances
        self.originalVoiceOverEnabled = originalVoiceOverEnabled
        self.restoredVoiceOverEnabled = restoredVoiceOverEnabled
        self.error = error
        self.limitations = limitations
    }
}

// swiftlint:enable multiline_parameters
