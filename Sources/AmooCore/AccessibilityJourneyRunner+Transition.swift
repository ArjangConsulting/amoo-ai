// SwiftFormat compact wrapping conflicts with SwiftLint argument layout.
// swiftlint:disable multiline_arguments multiline_parameters
import Foundation

extension AccessibilityJourneyRunner {
    // Keep precondition, action, destination and recovery checks in a single continuous service lifetime.
    // swiftlint:disable:next function_body_length
    static func transition(
        _ step: AccessibilityJourneyStep, service: any AccessibilityJourneyControlling,
        context: VoiceOverRunContext, result: inout AccessibilityInspection
    ) throws -> Bool {
        let before = try service.currentSpeech()
        capture(before, result: &result)
        try context.check()
        recordSpeech(
            step: step,
            suffix: "before",
            expected: step.before!,
            speech: before,
            truncated: before.count > 4096,
            result: &result
        )
        guard before.count <= 4096, step.before!.matches(before) else { return false }
        let target = step.element!
        let capturedTarget = try service.elements(id: target.id)
        let destination = step.destination!
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
        try service.perform(action: step.action!, elementID: target.id)
        try context.check()
        record(
            step: step,
            suffix: "action",
            elementID: target.id,
            source: "xctestGesture",
            outcome: .pass,
            expected: step.action!.rawValue,
            actual: "Gesture completed",
            result: &result
        )
        let nextDestination = try service.elements(id: destination.id)
        try context.check()
        capture(nextDestination, stage: "destinationAfter", result: &result)
        let destinationOutcome = combinedOutcome(expected: destination, captured: nextDestination)
        let changed = previousDestination != nextDestination
            && combinedOutcome(expected: destination, captured: previousDestination) != .pass
        let outcome: AccessibilityJourneyCheck.Outcome = destinationOutcome == .pass && !changed
            ? .needsReview : destinationOutcome
        record(
            step: step,
            suffix: "destination",
            elementID: destination.id,
            source: "exportedMetadata",
            outcome: outcome,
            expected: "Changed destination matching authored metadata",
            actual: nil,
            reason: changed ? "Destination checkpoint comparison"
                : "Destination already matched before the gesture; transition was not established",
            result: &result
        )
        guard outcome == .pass else { return false }
        let recovery = try awaitRecovery(step, service: service, context: context, result: &result)
        let after = recovery.speech
        guard recovery.withinDeadline else {
            record(
                step: step, suffix: "recovery", elementID: step.after!.elementID, source: "voiceOverSpeech",
                outcome: .notEvaluated, expected: step.after!.description, actual: after,
                reason: "Synchronous speech read completed after the authored recovery deadline", result: &result
            )
            return false
        }
        recordSpeech(
            step: step,
            suffix: "recovery",
            expected: step.after!,
            speech: after,
            truncated: after.count > 4096,
            result: &result
        )
        return after.count <= 4096 && step.after!.matches(after)
    }

    private static func awaitRecovery(
        _ step: AccessibilityJourneyStep, service: any AccessibilityJourneyControlling,
        context: VoiceOverRunContext, result: inout AccessibilityInspection
    ) throws -> (speech: String, withinDeadline: Bool) {
        let timeout = step.recoveryTimeoutMS ?? 2000
        let deadline = context.uptime() + Double(timeout) / 1000
        var speech = ""
        for sample in 0 ..< 21 {
            try context.check()
            speech = try service.currentSpeech()
            capture(speech, result: &result)
            try context.check()
            if timeout > 0, context.uptime() > deadline {
                return (speech, false)
            }
            if speech.count <= 4096, step.after!.matches(speech) {
                break
            }
            let remaining = deadline - context.uptime()
            if remaining <= 0 || sample == 20 {
                break
            }
            Thread.sleep(forTimeInterval: min(0.25, remaining))
            if context.uptime() >= deadline {
                break
            }
        }
        return (speech, true)
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
