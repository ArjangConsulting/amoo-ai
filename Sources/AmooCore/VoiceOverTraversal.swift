// SwiftFormat compact wrapping conflicts with argument layout lint.
// swiftlint:disable multiline_arguments multiline_parameters
import Foundation

/// Injectable public screen-reader operations, shared by the companion and fault-injection tests.
@MainActor
public protocol VoiceOverControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func move(direction: String) throws -> String
}

/// Bounded traversal with durable recovery and independent cleanup results.
@MainActor
public enum VoiceOverTraversal {
    /// Recover a previous interrupted command before serving another traversal.
    @discardableResult
    public static func recover(
        service: any VoiceOverControlling, journal: VoiceOverRecoveryJournal
    ) throws -> VoiceOverRecoveryJournal.Record? {
        guard let pending = try journal.load() else { return nil }
        try restore(service: service, enabled: pending.originalEnabled)
        try journal.clear()
        return pending
    }

    // Keep traversal and restoration in one linear, auditable state transition.
    // swiftlint:disable:next function_parameter_count
    public static func run(
        appID: String, phases: [VoiceOverPhase], service: any VoiceOverControlling,
        journal: VoiceOverRecoveryJournal, isTargetForeground: @escaping () -> Bool,
        isCancelled: @escaping () -> Bool,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        budget: TimeInterval = 90
    ) -> AccessibilityInspection {
        var result = AccessibilityInspection(status: "executionError", provider: "appleVoiceOver")
        result.requestedChecks = phases.indices.map { "traversal.phase.\($0)" }
        result.notEvaluatedReasons = Dictionary(uniqueKeysWithValues: result.requestedChecks.map {
            ($0, "Traversal phase did not complete")
        })
        do {
            try VoiceOverPhase.validate(phases)
            guard budget.isFinite, budget > 0 else { throw TraversalFailure.deadline }
        } catch {
            result.error = "Invalid traversal request: \(error)"
            return result
        }
        withRecovery(
            appID: appID, service: service, journal: journal,
            isTargetForeground: isTargetForeground, isCancelled: isCancelled, uptime: uptime,
            budget: budget, result: &result
        ) { context, result in
            for (index, phase) in phases.enumerated() {
                result.phases.append(.init(
                    phaseIndex: index, direction: phase.direction, requestedSteps: phase.steps, utterances: []
                ))
                for _ in 0 ..< phase.steps {
                    try context.check()
                    let speech = try service.move(direction: phase.direction)
                    let bounded = String(speech.prefix(4096))
                    result.truncated = result.truncated || speech.count > 4096
                    result.utterances.append(bounded)
                    result.phases[index].utterances.append(bounded)
                    try context.completedMove()
                }
                let checkID = "traversal.phase.\(index)"
                result.evaluatedChecks.append(checkID)
                result.notEvaluatedReasons.removeValue(forKey: checkID)
            }
        }
        result.limitations = [
            "Speech is observational; activation, rotor and task usability are not evaluated.",
            "A synchronous platform call cannot be interrupted; cancellation and deadlines are checked between calls.",
            "Recovery restores enabled state, not focus position; the journal retains counts, not speech."
        ]
        return result
    }

    static func restore(service: any VoiceOverControlling, enabled: Bool) throws {
        if service.isEnabled != enabled {
            try service.setEnabled(enabled)
        }
        guard service.isEnabled == enabled else { throw TraversalFailure.restoration }
    }

    static func check(isTargetForeground: @escaping () -> Bool, isCancelled: () -> Bool, expired: Bool) throws {
        if isCancelled() {
            throw CancellationError()
        }
        if expired {
            throw TraversalFailure.deadline
        }
        if !isTargetForeground() {
            throw TraversalFailure.wrongApp
        }
    }

    enum TraversalFailure: Error { case wrongApp, deadline, enabling, restoration }
}

// swiftlint:enable multiline_arguments multiline_parameters
