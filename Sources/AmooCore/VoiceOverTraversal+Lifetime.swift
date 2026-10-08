// SwiftFormat compact wrapping conflicts with SwiftLint argument layout.
// swiftlint:disable multiline_parameters
import Foundation

/// One service lifetime shared by observational traversal and authored journeys.
@MainActor
final class VoiceOverRunContext {
    let journal: VoiceOverRecoveryJournal
    var marker: VoiceOverRecoveryJournal.Record
    let uptime: () -> TimeInterval
    let checkOperation: () throws -> Void

    init(
        journal: VoiceOverRecoveryJournal,
        marker: VoiceOverRecoveryJournal.Record,
        uptime: @escaping () -> TimeInterval,
        check: @escaping () throws -> Void
    ) {
        self.journal = journal
        self.marker = marker
        self.uptime = uptime
        checkOperation = check
    }

    func check() throws {
        try checkOperation()
    }

    func completedMove() throws {
        marker.completedMoves += 1
        try journal.save(marker)
        try check()
    }
}

extension VoiceOverTraversal {
    // Restoration runs once, even when an assertion, action, cancellation or provider fails.
    // swiftlint:disable:next function_parameter_count
    static func withRecovery(
        appID: String, service: any VoiceOverControlling, journal: VoiceOverRecoveryJournal,
        isTargetForeground: @escaping () -> Bool, isCancelled: @escaping () -> Bool,
        uptime: @escaping () -> TimeInterval, budget: TimeInterval,
        result: inout AccessibilityInspection,
        operation: (VoiceOverRunContext, inout AccessibilityInspection) throws -> Void
    ) {
        guard budget.isFinite, budget > 0 else {
            result.error = "Invalid execution budget"
            return
        }
        let deadline = uptime() + budget
        do {
            try recover(service: service, journal: journal)
        } catch {
            result.error = "Cannot start traversal: \(error)"
            result.cleanupError = "Pending recovery must be resolved before changing VoiceOver."
            return
        }
        let original = service.isEnabled
        result.originalVoiceOverEnabled = original
        let marker = VoiceOverRecoveryJournal.Record(
            originalEnabled: original, appID: appID, completedMoves: 0, startedAt: Date()
        )
        let context = VoiceOverRunContext(journal: journal, marker: marker, uptime: uptime) {
            try check(isTargetForeground: isTargetForeground, isCancelled: isCancelled, expired: uptime() >= deadline)
        }
        do {
            try journal.save(marker)
            try context.check()
            if !original {
                try service.setEnabled(true)
            }
            guard service.isEnabled else { throw TraversalFailure.enabling }
            try operation(context, &result)
            result.status = "observed"
        } catch { result.error = String(describing: error) }
        do {
            try restore(service: service, enabled: original)
            result.restoredVoiceOverEnabled = service.isEnabled
            try journal.clear()
        } catch {
            result.restoredVoiceOverEnabled = service.isEnabled
            result.cleanupError = "Restoration remains pending: \(error)"
        }
    }
}

// swiftlint:enable multiline_parameters
