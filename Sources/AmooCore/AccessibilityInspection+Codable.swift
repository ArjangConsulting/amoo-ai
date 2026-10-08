import Foundation

/// Older companions and artifacts have unknown coverage rather than an inferred pass.
public extension AccessibilityInspection {
    private enum CodingKeys: String, CodingKey {
        case status, provider, issues, utterances
        case originalVoiceOverEnabled, restoredVoiceOverEnabled, error, limitations
        case requestedChecks, evaluatedChecks, notEvaluatedReasons, truncated
        case cleanupError, phases, provenance, journey
        case executionStatus, verdict, cleanupStatus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? "unknown"
        issues = try values.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        utterances = try values.decodeIfPresent([String].self, forKey: .utterances) ?? []
        originalVoiceOverEnabled = try values.decodeIfPresent(Bool.self, forKey: .originalVoiceOverEnabled)
        restoredVoiceOverEnabled = try values.decodeIfPresent(Bool.self, forKey: .restoredVoiceOverEnabled)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        limitations = try values.decodeIfPresent([String].self, forKey: .limitations) ?? []
        requestedChecks = try values.decodeIfPresent([String].self, forKey: .requestedChecks) ?? []
        evaluatedChecks = try values.decodeIfPresent([String].self, forKey: .evaluatedChecks) ?? []
        notEvaluatedReasons = try values.decodeIfPresent([String: String].self, forKey: .notEvaluatedReasons) ?? [:]
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        cleanupError = try values.decodeIfPresent(String.self, forKey: .cleanupError)
        journey = try values.decodeIfPresent(AccessibilityJourneyReport.self, forKey: .journey)
        phases = try values.decodeIfPresent([VoiceOverPhaseObservation].self, forKey: .phases) ?? []
        provenance = try values.decodeIfPresent([String: String].self, forKey: .provenance) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(journey, forKey: .journey)
        try values.encode(status, forKey: .status)
        try values.encode(provider, forKey: .provider)
        try values.encode(issues, forKey: .issues)
        try values.encode(utterances, forKey: .utterances)
        try values.encodeIfPresent(originalVoiceOverEnabled, forKey: .originalVoiceOverEnabled)
        try values.encodeIfPresent(restoredVoiceOverEnabled, forKey: .restoredVoiceOverEnabled)
        try values.encodeIfPresent(error, forKey: .error)
        try values.encode(limitations, forKey: .limitations)
        try values.encode(requestedChecks, forKey: .requestedChecks)
        try values.encode(evaluatedChecks, forKey: .evaluatedChecks)
        try values.encode(notEvaluatedReasons, forKey: .notEvaluatedReasons)
        try values.encode(truncated, forKey: .truncated)
        try values.encodeIfPresent(cleanupError, forKey: .cleanupError)
        try values.encode(phases, forKey: .phases)
        try values.encode(provenance, forKey: .provenance)
        try values.encode(executionStatus, forKey: .executionStatus)
        try values.encode(verdict, forKey: .verdict)
        try values.encode(cleanupStatus, forKey: .cleanupStatus)
    }
}
