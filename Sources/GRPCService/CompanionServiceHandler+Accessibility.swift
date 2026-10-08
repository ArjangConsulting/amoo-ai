import AmooCore
import Foundation
import GRPCCore
import Protos

// SwiftFormat's compact wrapping conflicts with SwiftLint's argument layout rule.
// swiftlint:disable multiline_arguments

package extension CompanionServiceHandler {
    // Linear wire conversion preserves independent coverage and cleanup fields.
    // swiftlint:disable:next function_body_length
    func inspectAccessibility(
        request: Amoo_AccessibilityInspectionRequest, context _: ServerContext
    ) async throws -> Amoo_AccessibilityInspectionResponse {
        guard request.phases.isEmpty || request.operation == "voiceOver" else {
            throw RPCError(code: .invalidArgument, message: "Phases require the voiceOver operation")
        }
        let inspection = if request.operation == "journey" {
            try await companion.inspectAccessibilityJourney(
                appID: request.appID,
                journey: AccessibilityJourney.decodeJSON(request.journeyJson)
            )
        } else if request.phases.isEmpty {
            try await companion.inspectAccessibility(
                appID: request.appID, operation: request.operation, categories: request.categories,
                steps: Int(request.steps), direction: request.direction
            )
        } else {
            try await companion.inspectVoiceOver(
                appID: request.appID,
                phases: request.phases.map { .init(steps: Int($0.steps), direction: $0.direction) }
            )
        }
        var response = Amoo_AccessibilityInspectionResponse()
        if let journey = inspection.journey {
            response.journeyReportJson = try String(bytes: JSONEncoder().encode(journey), encoding: .utf8) ?? ""
        }
        response.status = inspection.status
        response.provider = inspection.provider
        response.error = inspection.error ?? ""
        response.limitations = inspection.limitations
        response.utterances = inspection.utterances
        response.requestedChecks = inspection.requestedChecks
        response.evaluatedChecks = inspection.evaluatedChecks
        response.notEvaluatedReasons = inspection.notEvaluatedReasons
        response.truncated = inspection.truncated
        response.cleanupError = inspection.cleanupError ?? ""
        response.provenance = inspection.provenance
        response.phases = inspection.phases.map {
            var phase = Amoo_VoiceOverPhaseObservation()
            phase.phaseIndex = UInt32($0.phaseIndex)
            phase.direction = $0.direction
            phase.requestedSteps = UInt32($0.requestedSteps)
            phase.utterances = $0.utterances
            return phase
        }
        if let original = inspection.originalVoiceOverEnabled {
            response.originalVoiceoverEnabled = original
        }
        if let restored = inspection.restoredVoiceOverEnabled {
            response.restoredVoiceoverEnabled = restored
        }
        response.issues = inspection.issues.map {
            var issue = Amoo_AccessibilityInspectionIssue()
            issue.category = $0.category
            issue.description_p = $0.description
            issue.details = $0.details
            if $0.elementID != nil || $0.label != nil {
                var element = Amoo_ElementInfo()
                element.id = $0.elementID ?? ""
                element.label = $0.label ?? ""
                issue.element = element
            }
            return issue
        }
        return response
    }
}

// swiftlint:enable multiline_arguments
