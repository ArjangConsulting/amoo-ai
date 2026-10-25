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
        public var frame: Rect?
        public var value: String?
        public var elementType: String?
        public var semantics: ElementSemantics?

        public init(
            category: String, description: String, details: String, elementID: String?, label: String?,
            frame: Rect? = nil, value: String? = nil, elementType: String? = nil,
            semantics: ElementSemantics? = nil
        ) {
            self.category = category
            self.description = description
            self.details = details
            self.elementID = elementID
            self.label = label
            self.frame = frame
            self.value = value
            self.elementType = elementType
            self.semantics = semantics
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
        if provider == "androidTalkBack", let raw = provenance["speech_expectations_json"],
           let expected = try? JSONDecoder().decode([AccessibilitySpeechExpectation].self, from: Data(raw.utf8)),
           (1 ... 30).contains(expected.count), expected.allSatisfy({
               ($0.equals != nil) != ($0.contains != nil) && $0.elementID == nil
           }) {
            let mismatched = phases.contains { phase in
                expected.indices.contains(phase.phaseIndex)
                    && evaluatedChecks.contains("talkBack.move.\(phase.phaseIndex)") && !phase.utterances.isEmpty
                    && !expected[phase.phaseIndex].matches(phase.utterances.joined(separator: " "))
            }
            if mismatched {
                return "fail"
            }
            guard status == "pass", !truncated, phases.count == expected.count,
                  Set(phases.map(\.phaseIndex)) == Set(expected.indices),
                  phases.allSatisfy({ $0.requestedSteps == 1 && !$0.utterances.isEmpty }),
                  evaluatedChecks.count == expected.count, Set(requestedChecks) == Set(evaluatedChecks),
                  notEvaluatedReasons.isEmpty else { return "notAssessed" }
            return "pass"
        }
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
        guard ["appleNativeAudit", "androidNativeATF"].contains(provider) else { return "notAssessed" }
        if provider == "androidNativeATF" {
            if issues.contains(where: { $0.semantics?.attributes["resultType"] == "ERROR" }) {
                return "fail"
            }
            guard issues.isEmpty else { return "notAssessed" }
        }
        if !issues.isEmpty {
            return "fail"
        }
        guard status == "pass", !truncated, !evaluatedChecks.isEmpty,
              Set(requestedChecks) == Set(evaluatedChecks), notEvaluatedReasons.isEmpty else { return "notAssessed" }
        return "pass"
    }

    public var cleanupStatus: String {
        if provider == "androidTalkBack" {
            if cleanupError != nil {
                return "failed"
            }
            if status == "unsupported" {
                return "notRequired"
            }
            return provenance["restoration_status"] ?? "unknown"
        }
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
