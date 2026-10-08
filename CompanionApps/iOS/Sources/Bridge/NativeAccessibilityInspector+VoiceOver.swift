import Foundation
import XCTest

extension NativeAccessibilityInspector {
    /// Xcode recreates the runner's private container after a crash. The installed host app
    /// anchors this shared container; never fall back to the runner's volatile Application Support.
    nonisolated static var recoveryJournal: VoiceOverRecoveryJournal {
        get throws {
            let group = Bundle(for: CompanionRunner.self)
                .object(forInfoDictionaryKey: "AmooRecoveryAppGroup") as? String ?? "group.com.amoo.companion"
            guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return VoiceOverRecoveryJournal(
                url: root.appending(path: "Library/Application Support/amoo/voiceover-recovery.json")
            )
        }
    }

    static var startupVoiceOverRecovery: [String: String] = ["startup_voiceover_recovery": "notAttempted"]

    static func recoverVoiceOverAtStartup() {
        if #available(iOS 27.0, *) {
            do {
                let recovered = try VoiceOverTraversal.recover(
                    service: XCTestVoiceOverControl(), journal: recoveryJournal
                )
                startupVoiceOverRecovery = ["startup_voiceover_recovery": recovered == nil ? "none" : "restored"]
                if let recovered {
                    startupVoiceOverRecovery["startup_voiceover_original_enabled"] = String(recovered.originalEnabled)
                    startupVoiceOverRecovery["startup_voiceover_completed_moves"] = String(recovered.completedMoves)
                }
            } catch {
                startupVoiceOverRecovery = ["startup_voiceover_recovery": "failed"]
                print("[Accessibility] VoiceOver restoration pending; traversal will remain blocked.")
            }
        }
    }

    static func voiceOverResponse(_ report: AccessibilityInspection) -> Amoo_AccessibilityInspectionResponse {
        var result = Amoo_AccessibilityInspectionResponse()
        result.status = report.status
        result.provider = report.provider
        result.error = report.error ?? ""
        result.cleanupError = report.cleanupError ?? ""
        result.utterances = report.utterances
        result.requestedChecks = report.requestedChecks
        result.evaluatedChecks = report.evaluatedChecks
        result.notEvaluatedReasons = report.notEvaluatedReasons
        result.truncated = report.truncated
        result.limitations = report.limitations
        if let original = report.originalVoiceOverEnabled {
            result.originalVoiceoverEnabled = original
        }
        if let restored = report.restoredVoiceOverEnabled {
            result.restoredVoiceoverEnabled = restored
        }
        result.phases = report.phases.map {
            var phase = Amoo_VoiceOverPhaseObservation()
            phase.phaseIndex = UInt32($0.phaseIndex)
            phase.direction = $0.direction
            phase.requestedSteps = UInt32($0.requestedSteps)
            phase.utterances = $0.utterances
            return phase
        }
        return result
    }
}

@available(iOS 27.0, *)
@MainActor
final class XCTestVoiceOverControl: VoiceOverControlling {
    var isEnabled: Bool {
        XCUIDevice.shared.voiceOverService.isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try XCUIDevice.shared.voiceOverService.enable()
        } else {
            try XCUIDevice.shared.voiceOverService.disable()
        }
    }

    func move(direction: String) throws -> String {
        let service = XCUIDevice.shared.voiceOverService
        return try direction == "forward" ? service.moveForward().utterance : service.moveBackward().utterance
    }
}
