// SwiftFormat compact wrapping conflicts with SwiftLint argument layout.
// swiftlint:disable multiline_arguments multiline_parameters
import Foundation

extension AccessibilityJourneyRunner {
    static func metadataOutcome(
        captured: [AccessibilityElementEvidence], field: String, expected: String
    ) -> AccessibilityJourneyCheck.Outcome {
        if captured.isEmpty {
            return .fail
        }
        guard captured.count == 1 else { return .needsReview }
        guard let actual = captured[0].fields[field], actual.count <= 4096 else { return .unsupported }
        return actual == expected ? .pass : .fail
    }

    static func capture(
        _ elements: [AccessibilityElementEvidence], stage: String = "element", result: inout AccessibilityInspection
    ) {
        let bounded = elements.prefix(2).map { element in
            var copy = element
            for value in [element.name, element.role, element.value].compactMap(\.self) where value.count > 4096 {
                result.truncated = true
            }
            copy.name = copy.name.map { String($0.prefix(4096)) }
            copy.role = copy.role.map { String($0.prefix(4096)) }
            copy.value = copy.value.map { String($0.prefix(4096)) }
            return copy
        }
        guard let index = result.journey?.checkpoints.indices.last else { return }
        result.journey?.checkpoints[index].elements.append(contentsOf: bounded)
        if result.journey?.checkpoints[index].elementCaptures == nil {
            result.journey?.checkpoints[index].elementCaptures = []
        }
        result.journey?.checkpoints[index].elementCaptures?.append(.init(stage: stage, elements: bounded))
    }

    @discardableResult
    static func capture(_ speech: String, result: inout AccessibilityInspection) -> String {
        let bounded = String(speech.prefix(4096))
        result.truncated = result.truncated || speech.count > 4096
        guard result.utterances.count < 128 else {
            result.truncated = true
            return bounded
        }
        result.utterances.append(bounded)
        if let index = result.journey?.checkpoints.indices.last {
            result.journey?.checkpoints[index].utterances.append(bounded)
        }
        return bounded
    }

    /// A valid journey makes at most 68 decisive reads (30 moves, plus a before and a final recovery
    /// read for each of at most 19 transitions alongside a move step). Stopping polls at 48 keeps the
    /// total under the 128-utterance cap, so polling can never truncate a decisive read.
    static let recoveryPollBudget = 48

    /// Recovery reads repeat while focus is unchanged, so a repeat of the checkpoint's last utterance
    /// is kept once. Intermediate polls are supplementary: beyond the budget they are dropped without
    /// marking truncation. The decisive read is always retained, and its own oversize still counts.
    static func captureRecoveryRead(_ speech: String, decisive: Bool, result: inout AccessibilityInspection) {
        let bounded = String(speech.prefix(4096))
        guard let index = result.journey?.checkpoints.indices.last,
              result.journey?.checkpoints[index].utterances.last != bounded else {
            result.truncated = result.truncated || (decisive && speech.count > 4096)
            return
        }
        if decisive {
            capture(speech, result: &result)
        } else if result.utterances.count < recoveryPollBudget {
            result.utterances.append(bounded)
            result.journey?.checkpoints[index].utterances.append(bounded)
        }
    }

    static func recordSpeech(
        step: AccessibilityJourneyStep, suffix: String, expected: AccessibilitySpeechExpectation,
        speech: String, truncated: Bool = false, result: inout AccessibilityInspection
    ) {
        record(
            step: step, suffix: suffix, elementID: expected.elementID, source: "voiceOverSpeech",
            outcome: truncated ? .unsupported : expected.matches(speech) ? .pass : .fail,
            expected: expected.description, actual: speech,
            reason: truncated ? "Speech exceeded the evidence bound" : "Authored speech comparison",
            result: &result
        )
    }

    // swiftlint:disable:next function_parameter_count
    static func record(
        step: AccessibilityJourneyStep, suffix: String, elementID: String?, source: String,
        outcome: AccessibilityJourneyCheck.Outcome, expected: String, actual: String?,
        reason: String = "Authored exported-metadata comparison", result: inout AccessibilityInspection
    ) {
        let id = "\(step.id).\(suffix)"
        result.journey?.checks.append(.init(
            id: id, checkpointID: step.id, elementID: elementID,
            transitionID: step.kind == .transition ? step.id : nil,
            source: source, outcome: outcome, expected: expected,
            actual: actual.map { String($0.prefix(4096)) }, reason: reason
        ))
        if [.pass, .fail].contains(outcome) {
            result.evaluatedChecks.append(id)
            result.notEvaluatedReasons.removeValue(forKey: id)
        } else {
            result.notEvaluatedReasons[id] = reason
        }
    }
}

// swiftlint:enable multiline_arguments multiline_parameters
