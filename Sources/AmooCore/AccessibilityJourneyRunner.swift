// SwiftFormat compact wrapping conflicts with SwiftLint argument layout.
// swiftlint:disable multiline_arguments multiline_parameters
import Foundation

/// Public platform operations. Actions are ordinary XCTest gestures, not an inferred VoiceOver activation API.
@MainActor
public protocol AccessibilityJourneyControlling: VoiceOverControlling {
    func currentSpeech() throws -> String
    func elements(id: String) throws -> [AccessibilityElementEvidence]
    func perform(action: AccessibilityJourneyStep.Action, elementID: String) throws
}

/// Evaluates only authored expectations, retaining incomplete coverage and one verified restoration.
@MainActor
public enum AccessibilityJourneyRunner {
    // swiftlint:disable:next function_parameter_count
    public static func run(
        appID: String, journey: AccessibilityJourney, service: any AccessibilityJourneyControlling,
        journal: VoiceOverRecoveryJournal, isTargetForeground: @escaping () -> Bool,
        isCancelled: @escaping () -> Bool,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, budget: TimeInterval = 90
    ) -> AccessibilityInspection {
        var result = AccessibilityInspection(status: "executionError", provider: "authoredAccessibilityJourney")
        do {
            try journey.validate()
        } catch {
            result.error = "Invalid journey: \(error)"
            return result
        }
        result.journey = .init(id: journey.id, specification: journey)
        result.requestedChecks = journey.requestedChecks
        result.notEvaluatedReasons = Dictionary(uniqueKeysWithValues: journey.requestedChecks.map {
            ($0, "Checkpoint was not reached")
        })
        VoiceOverTraversal.withRecovery(
            appID: appID, service: service, journal: journal,
            isTargetForeground: isTargetForeground, isCancelled: isCancelled,
            uptime: uptime, budget: budget, result: &result
        ) { context, result in
            for step in journey.steps {
                try context.check()
                result.journey?.checkpoints.append(.init(id: step.id))
                let shouldContinue = try execute(step, service: service, context: context, result: &result)
                if !shouldContinue {
                    break
                }
            }
        }
        fillUnreachedChecks(journey: journey, result: &result)
        result.limitations = [
            "Expectations are authored task checks, not whole-app accessibility conformance.",
            "Name/role/state use exported XCTest metadata, not a complete raw accessibility trait set.",
            "Speech matches are locale-specific; target element IDs are author associations, not observed focus IDs.",
            "Transitions use ordinary targeted XCTest gestures; rotor, custom actions and screen-reader activation"
                + " semantics are not certified.",
            "Focus recovery reads current speech within a bounded wait, without moving or re-enabling VoiceOver.",
            "A synchronous platform call cannot be interrupted; cancellation/deadlines are checked between calls."
        ]
        return result
    }

    private static func execute(
        _ step: AccessibilityJourneyStep, service: any AccessibilityJourneyControlling,
        context: VoiceOverRunContext, result: inout AccessibilityInspection
    ) throws -> Bool {
        switch step.kind {
        case .element:
            let expected = step.element!
            let captured = try service.elements(id: expected.id)
            try context.check()
            capture(captured, result: &result)
            for (field, value) in expected.fields {
                let observed = captured.count == 1 ? captured[0].fields[field] : nil
                let outcome = metadataOutcome(captured: captured, field: field, expected: value)
                record(
                    step: step, suffix: field, elementID: expected.id, source: "exportedMetadata",
                    outcome: outcome, expected: value, actual: observed, result: &result
                )
            }
            return true
        case .seek, .order:
            return try traverse(step, service: service, context: context, result: &result)
        case .transition:
            return try transition(step, service: service, context: context, result: &result)
        }
    }

    private static func traverse(
        _ step: AccessibilityJourneyStep, service: any AccessibilityJourneyControlling,
        context: VoiceOverRunContext, result: inout AccessibilityInspection
    ) throws -> Bool {
        let expectations = step.speech!
        let count = step.kind == .seek ? step.maxMoves! : expectations.count
        var lastSpeech: String?
        for index in 0 ..< count {
            try context.check()
            let raw = try service.move(direction: step.direction!)
            let speech = capture(raw, result: &result)
            lastSpeech = speech
            try context.completedMove()
            let expected = expectations[step.kind == .seek ? 0 : index]
            if step.kind == .seek {
                if raw.count <= 4096, expected.matches(speech) {
                    recordSpeech(step: step, suffix: "seek", expected: expected, speech: speech, result: &result)
                    return true
                }
            } else {
                recordSpeech(
                    step: step,
                    suffix: "order.\(index)",
                    expected: expected,
                    speech: speech,
                    truncated: raw.count > 4096,
                    result: &result
                )
            }
        }
        if step.kind == .seek {
            record(
                step: step,
                suffix: "seek",
                elementID: expectations[0].elementID,
                source: "voiceOverSpeech",
                outcome: result.truncated ? .unsupported : .fail,
                expected: expectations[0].description,
                actual: lastSpeech,
                reason: "Anchor not observed within the authored move bound",
                result: &result
            )
            return false
        }
        return result.journey?.checks.filter { $0.checkpointID == step.id }.allSatisfy { $0.outcome == .pass } == true
    }

    private static func fillUnreachedChecks(journey: AccessibilityJourney, result: inout AccessibilityInspection) {
        let recorded = Set(result.journey?.checks.map(\.id) ?? [])
        for step in journey.steps {
            for id in AccessibilityJourney(id: journey.id, steps: [step]).requestedChecks where !recorded.contains(id) {
                result.journey?.checks.append(.init(
                    id: id, checkpointID: step.id, elementID: step.element?.id,
                    transitionID: step.kind == .transition ? step.id : nil,
                    source: "none", outcome: .notEvaluated, expected: "Authored checkpoint expectation",
                    actual: nil, reason: result.error ?? "Earlier prerequisite did not pass"
                ))
            }
        }
    }
}

extension AccessibilityElementEvidence {
    var fields: [String: String] {
        var fields: [String: String] = [:]
        fields["name"] = name
        fields["role"] = role
        fields["value"] = value
        fields["enabled"] = enabled.map(String.init)
        fields["selected"] = selected.map(String.init)
        return fields
    }
}

// swiftlint:enable multiline_arguments multiline_parameters
