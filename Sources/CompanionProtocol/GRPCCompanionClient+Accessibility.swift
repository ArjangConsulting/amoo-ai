import AmooCore
import Foundation
import Protos

// SwiftFormat's compact wrapping conflicts with SwiftLint's argument layout rule.
// swiftlint:disable multiline_arguments

public extension GRPCCompanionClient {
    func inspectAccessibility(
        appID: String, operation: String, categories: [String], steps: Int, direction: String
    ) async throws -> AccessibilityInspection {
        try AccessibilityInspectionOptions.validate(
            operation: operation, categories: categories, steps: steps, direction: direction
        )
        var request = Amoo_AccessibilityInspectionRequest()
        request.appID = appID
        request.operation = operation
        request.categories = categories
        request.steps = UInt32(steps)
        request.direction = direction
        return try await executeInspection(request)
    }

    func inspectAccessibilityJourney(
        appID: String,
        journey: AccessibilityJourney
    ) async throws -> AccessibilityInspection {
        try journey.validate()
        var request = Amoo_AccessibilityInspectionRequest()
        request.appID = appID
        request.operation = "journey"
        request.journeyJson = try String(bytes: JSONEncoder().encode(journey), encoding: .utf8) ?? ""
        return try await executeInspection(request)
    }

    func inspectVoiceOver(appID: String, phases: [VoiceOverPhase]) async throws -> AccessibilityInspection {
        try VoiceOverPhase.validate(phases)
        var request = Amoo_AccessibilityInspectionRequest()
        request.appID = appID
        request.operation = "voiceOver"
        request.phases = phases.map {
            var phase = Amoo_VoiceOverPhase()
            phase.steps = UInt32($0.steps)
            phase.direction = $0.direction
            return phase
        }
        return try await executeInspection(request)
    }

    // Keep capability negotiation, transport failure and provider conversion together.
    // swiftlint:disable:next function_body_length
    private func executeInspection(_ request: Amoo_AccessibilityInspectionRequest) async throws
        -> AccessibilityInspection {
        let journey = request.operation == "journey"
            ? try JSONDecoder().decode(AccessibilityJourney.self, from: Data(request.journeyJson.utf8)) : nil
        let provider = if journey != nil {
            "authoredAccessibilityJourney"
        } else if request.operation == "nativeAudit" {
            "appleNativeAudit"
        } else {
            "appleVoiceOver"
        }
        let required = if journey != nil {
            "accessibility.authoredJourney.v1"
        } else if request.operation == "nativeAudit" {
            "accessibility.nativeAudit"
        } else if request.phases.isEmpty {
            "accessibility.voiceOverTraversal"
        } else {
            "accessibility.voiceOverPhases"
        }
        let capabilities = try await getCapabilities()
        let requirements = request.operation == "nativeAudit" ? [required] : [
            required,
            "accessibility.voiceOverRecovery"
        ]
        let supported = Set(capabilities.filter(\.supported).map(\.key))
        if let missing = requirements.first(where: { !supported.contains($0) }) {
            return AccessibilityInspection(
                status: "unsupported",
                provider: provider,
                error: "Companion does not advertise \(missing). Rebuild the companion and start_session with"
                    + " build_mode=rebuild in the owning MCP process; an older OS may require upgrading.",
                requestedChecks: journey?.requestedChecks ?? [],
                notEvaluatedReasons: Dictionary(uniqueKeysWithValues: (journey?.requestedChecks ?? []).map {
                    ($0, "Required capability is unavailable")
                }),
                provenance: [
                    "required_capability": missing,
                    "capabilities": capabilities.filter(\.supported).map(\.key).sorted()
                        .joined(separator: ",")
                ]
            )
        }
        let response: Amoo_AccessibilityInspectionResponse
        do {
            response = try await rpcClient.inspectAccessibility(request)
        } catch {
            let checks = journey?.requestedChecks ?? (request.operation == "nativeAudit" ? request.categories
                : (request.phases.isEmpty ? [Amoo_VoiceOverPhase()] : request.phases).indices.map {
                    "traversal.phase.\($0)"
                })
            return AccessibilityInspection(
                status: "executionError",
                provider: provider,
                error: "Inspection transport failed: \(error)",
                limitations: ["Client timeout/cancellation does not prove platform completion or restoration."
                    + " Reconnect in the owning process; the companion recovers its durable marker at startup."],
                requestedChecks: checks,
                notEvaluatedReasons: Dictionary(
                    checks.map { ($0, "Transport ended before completion evidence arrived") },
                    uniquingKeysWith: { first, _ in first }
                ),
                provenance: ["capabilities": capabilities.filter(\.supported).map(\.key).sorted()
                    .joined(separator: ",")]
            )
        }
        let journeyReport = response.journeyReportJson.isEmpty ? nil
            : try? JSONDecoder().decode(AccessibilityJourneyReport.self, from: Data(response.journeyReportJson.utf8))
        if let journey {
            guard journeyReport?.schemaVersion == 1, journeyReport?.id == journey.id,
                  journeyReport?.specification == journey,
                  response.provider == provider,
                  Set(response.requestedChecks) == Set(journey.requestedChecks),
                  Set(journeyReport?.checks.map(\.id) ?? []) == Set(journey.requestedChecks),
                  journeyReport?.checks.count == journey.requestedChecks.count else {
                return AccessibilityInspection(
                    status: "executionError", provider: provider,
                    error: "Companion returned incomplete or mismatched authored-journey evidence",
                    requestedChecks: journey.requestedChecks,
                    notEvaluatedReasons: Dictionary(uniqueKeysWithValues: journey.requestedChecks.map {
                        ($0, "Unvalidated companion response")
                    })
                )
            }
        }
        return AccessibilityInspection(
            status: response.status, provider: response.provider,
            issues: response.issues.map {
                .init(
                    category: $0.category, description: $0.description_p, details: $0.details,
                    elementID: $0.hasElement ? $0.element.id : nil,
                    label: $0.hasElement ? $0.element.label : nil
                )
            },
            utterances: response.utterances,
            originalVoiceOverEnabled: response.hasOriginalVoiceoverEnabled ? response.originalVoiceoverEnabled : nil,
            restoredVoiceOverEnabled: response.hasRestoredVoiceoverEnabled ? response.restoredVoiceoverEnabled : nil,
            error: response.error.isEmpty ? nil : response.error, limitations: response.limitations,
            requestedChecks: response.requestedChecks, evaluatedChecks: response.evaluatedChecks,
            notEvaluatedReasons: response.notEvaluatedReasons, truncated: response.truncated,
            cleanupError: response.cleanupError.isEmpty ? nil : response.cleanupError,
            phases: response.phases.map {
                .init(
                    phaseIndex: Int($0.phaseIndex),
                    direction: $0.direction,
                    requestedSteps: Int($0.requestedSteps),
                    utterances: $0.utterances
                )
            },
            provenance: response.provenance.merging(
                ["capabilities": capabilities.filter(\.supported).map(\.key).sorted().joined(separator: ",")],
                uniquingKeysWith: { existing, _ in existing }
            ),
            journey: journeyReport
        )
    }
}

// swiftlint:enable multiline_arguments
