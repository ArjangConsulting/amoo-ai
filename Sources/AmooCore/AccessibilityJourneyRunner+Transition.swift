// SwiftFormat compact wrapping conflicts with SwiftLint argument layout.
// swiftlint:disable multiline_arguments multiline_parameters
import Foundation

extension AccessibilityJourneyRunner {
    /// What the bounded recovery wait established about focus at the authored deadline.
    enum RecoveryObservation: Equatable {
        /// Expected speech was read in a sample that completed by the deadline.
        case recovered
        /// Expected speech was first read in a sample that completed after the deadline.
        case late
        /// A sample started at or after the deadline still read other speech.
        case notRecovered
        /// Sampling ended without a decisive sample.
        case undetermined
    }

    // Keep precondition, action, destination and recovery checks in a single continuous service lifetime.
    // swiftlint:disable:next function_body_length
    static func transition(
        _ step: AccessibilityJourneyStep, service: any AccessibilityJourneyControlling,
        context: VoiceOverRunContext, result: inout AccessibilityInspection
    ) throws -> Bool {
        guard let target = step.element, let destination = step.destination, let action = step.action,
              let beforeExpectation = step.before, let afterExpectation = step.after
        else { throw AccessibilityJourneyValidationError() }
        let before = try service.currentSpeech()
        capture(before, result: &result)
        try context.check()
        recordSpeech(
            step: step,
            suffix: "before",
            expected: beforeExpectation,
            speech: before,
            truncated: before.count > 4096,
            result: &result
        )
        guard before.count <= 4096, beforeExpectation.matches(before) else { return false }
        let capturedTarget = try service.elements(id: target.id)
        let previousDestination = try service.elements(id: destination.id)
        try context.check()
        capture(capturedTarget, stage: "targetBefore", result: &result)
        capture(previousDestination, stage: "destinationBefore", result: &result)
        let targetOutcome = combinedOutcome(expected: target, captured: capturedTarget)
        guard targetOutcome == .pass else {
            record(
                step: step,
                suffix: "action",
                elementID: target.id,
                source: "exportedMetadata",
                outcome: targetOutcome,
                expected: "Unique target matching authored metadata",
                actual: nil,
                reason: "Action withheld: target precondition did not pass",
                result: &result
            )
            return false
        }
        // Never repair focus before checking recovery. The action is the only intervening gesture.
        try service.perform(action: action, elementID: target.id)
        try context.check()
        record(
            step: step,
            suffix: "action",
            elementID: target.id,
            source: "xctestGesture",
            outcome: .pass,
            expected: action.rawValue,
            actual: "Gesture completed",
            result: &result
        )
        let nextDestination = try service.elements(id: destination.id)
        try context.check()
        capture(nextDestination, stage: "destinationAfter", result: &result)
        let destinationOutcome = combinedOutcome(expected: destination, captured: nextDestination)
        let matchedBefore = combinedOutcome(expected: destination, captured: previousDestination) == .pass
        let outcome: AccessibilityJourneyCheck.Outcome = destinationOutcome == .pass && matchedBefore
            ? .needsReview : destinationOutcome
        let reason = if destinationOutcome != .pass {
            "Destination did not match authored metadata after the gesture"
        } else if matchedBefore {
            "Destination already matched before the gesture; transition was not established"
        } else {
            "Destination changed to match authored metadata after the gesture"
        }
        record(
            step: step,
            suffix: "destination",
            elementID: destination.id,
            source: "exportedMetadata",
            outcome: outcome,
            expected: "Changed destination matching authored metadata",
            actual: nil,
            reason: reason,
            result: &result
        )
        guard outcome == .pass else { return false }
        let recovery = try awaitRecovery(
            step, expected: afterExpectation, service: service, context: context, result: &result
        )
        switch recovery.observation {
        case .late, .undetermined:
            record(
                step: step, suffix: "recovery", elementID: afterExpectation.elementID, source: "voiceOverSpeech",
                outcome: .notEvaluated, expected: afterExpectation.description, actual: recovery.speech,
                reason: recovery.observation == .late
                    ? "Expected speech was first read after the authored recovery deadline"
                    : "Recovery sampling ended without a sample at the authored deadline",
                result: &result
            )
            return false
        case .recovered, .notRecovered:
            recordSpeech(
                step: step,
                suffix: "recovery",
                expected: afterExpectation,
                speech: recovery.speech,
                truncated: recovery.speech.count > 4096,
                result: &result
            )
            return recovery.observation == .recovered
        }
    }

    /// Polls current speech until it matches or the deadline passes. A match counts only when its
    /// read completed by the deadline; a mismatch counts only when its read started at or after it.
    /// The last poll is timed to complete just before the deadline, so focus that settles after
    /// the previous poll is still observed, and a mismatch there is confirmed by one more read.
    private static func awaitRecovery(
        _ step: AccessibilityJourneyStep, expected: AccessibilitySpeechExpectation,
        service: any AccessibilityJourneyControlling, context: VoiceOverRunContext,
        result: inout AccessibilityInspection
    ) throws -> (speech: String, observation: RecoveryObservation) {
        let timeout = step.recoveryTimeoutMS ?? 2000
        let deadline = context.uptime() + Double(timeout) / 1000
        var speech = ""
        var slowestRead: TimeInterval = 0
        // 0.25 s polls across at most 5 s, a final in-bound read and a confirming read; the rest absorb jitter.
        for _ in 0 ..< 26 {
            try context.check()
            let started = context.uptime()
            speech = try service.currentSpeech()
            let completed = context.uptime()
            slowestRead = max(slowestRead, completed - started)
            let observation: RecoveryObservation? = if speech.count <= 4096, expected.matches(speech) {
                timeout == 0 || completed <= deadline ? .recovered : .late
            } else if started >= deadline {
                .notRecovered
            } else {
                nil
            }
            captureRecoveryRead(speech, decisive: observation != nil, result: &result)
            try context.check()
            if let observation {
                return (speech, observation)
            }
            let now = context.uptime()
            // Latest start that should still complete by the deadline, judged by the slowest read so far.
            let finalStart = deadline - slowestRead * 1.5 - 0.01
            let next = now < finalStart ? min(now + 0.25, finalStart) : deadline
            if next > now {
                context.sleep(next - now)
            }
        }
        return (speech, .undetermined)
    }

    private static func combinedOutcome(
        expected: AccessibilityElementExpectation, captured: [AccessibilityElementEvidence]
    ) -> AccessibilityJourneyCheck.Outcome {
        let outcomes = expected.fields.map { metadataOutcome(captured: captured, field: $0.0, expected: $0.1) }
        if outcomes.contains(.fail) {
            return .fail
        }
        if outcomes.contains(.needsReview) {
            return .needsReview
        }
        if outcomes.contains(.unsupported) {
            return .unsupported
        }
        return .pass
    }
}

// swiftlint:enable multiline_arguments multiline_parameters
