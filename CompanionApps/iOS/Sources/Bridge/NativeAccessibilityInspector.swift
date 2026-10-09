import CryptoKit
import Foundation
import XCTest

/// Public XCTest APIs only. Each VoiceOver request is self-contained and restores its state.
@MainActor
enum NativeAccessibilityInspector {
    static let buildFingerprint = binaryFingerprint(Bundle(for: CompanionRunner.self))

    static func inspect(
        _ request: Amoo_AccessibilityInspectionRequest,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Amoo_AccessibilityInspectionResponse {
        var result = perform(request, isCancelled: isCancelled)
        let bundle = Bundle(for: CompanionRunner.self)
        result.provenance = [
            "companion_bundle": bundle.bundleIdentifier ?? "unknown",
            "companion_build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "companion_fingerprint": buildFingerprint,
            "device_os": ProcessInfo.processInfo.operatingSystemVersionString,
            "companion_locale": Locale.current.identifier,
            "app_build": "unavailable from external inspection",
            "app_locale": "unavailable from external inspection"
        ].merging(startupVoiceOverRecovery, uniquingKeysWith: { existing, _ in existing })
        return result
    }

    private static func binaryFingerprint(_ bundle: Bundle) -> String {
        guard let url = bundle.executableURL, let data = try? Data(contentsOf: url) else { return "unknown" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func perform(
        _ request: Amoo_AccessibilityInspectionRequest,
        isCancelled: @escaping @Sendable () -> Bool
    )
        -> Amoo_AccessibilityInspectionResponse {
        var result = Amoo_AccessibilityInspectionResponse()
        result.provider = request.operation == "journey" ? "authoredAccessibilityJourney"
            : request.operation == "nativeAudit" ? "appleNativeAudit" : "appleVoiceOver"
        result.status = "executionError"
        let app = XCUIApplication(bundleIdentifier: request.appID)
        guard !request.appID.isEmpty, app.state == .runningForeground else {
            result.error = "Inspection requires the requested app in the foreground."
            return result
        }
        switch request.operation {
        case "nativeAudit":
            // Resolve the current UI process after launch, before the audit service binds its PID.
            do { _ = try app.snapshot() }
            catch {
                result.error = "Unable to establish audit readiness: \(error)"
                return result
            }
            return audit(app, categories: request.categories, isCancelled: isCancelled)
        case "journey":
            return authoredJourney(request, isCancelled: isCancelled)
        case "voiceOver":
            let phases: [Amoo_VoiceOverPhase]
            if request.phases.isEmpty {
                var phase = Amoo_VoiceOverPhase()
                phase.steps = request.steps
                phase.direction = request.direction
                phases = [phase]
            } else {
                phases = request.phases
            }
            guard (1 ... 6).contains(phases.count),
                  phases
                  .allSatisfy({ (1 ... 30).contains($0.steps) && ["forward", "backward"].contains($0.direction) }),
                  phases.reduce(UInt64(0), { $0 + UInt64($1.steps) }) <= 30 else {
                result.error = "Requires 1...6 forward/backward phases and at most 30 total moves."
                return result
            }
            if #available(iOS 27.0, *) {
                return traverse(appID: request.appID, phases: phases, isCancelled: isCancelled)
            }
            result.status = "unsupported"
            result.error = "Public VoiceOver service requires iOS 27 or newer."
        default:
            result.error = "Unknown inspection operation."
        }
        return result
    }

    private static func audit(
        _ app: XCUIApplication,
        categories: [String],
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Amoo_AccessibilityInspectionResponse {
        let types: [String: XCUIAccessibilityAuditType] = [
            "contrast": .contrast, "elementDetection": .elementDetection, "hitRegion": .hitRegion,
            "sufficientElementDescription": .sufficientElementDescription, "dynamicType": .dynamicType,
            "textClipped": .textClipped, "trait": .trait
        ]
        var result = Amoo_AccessibilityInspectionResponse()
        result.provider = "appleNativeAudit"
        result.requestedChecks = categories
        result.notEvaluatedReasons = Dictionary(
            categories.map { ($0, "Audit did not complete") },
            uniquingKeysWith: { a, _ in a }
        )
        result.status = "executionError"
        result
            .limitations = ["Current presentation only; no whole-app conformance or VoiceOver task completion verdict."]
        guard !categories.isEmpty, categories.allSatisfy({ types[$0] != nil }) else {
            result.error = "Native audit requires supported, nonempty categories."
            return result
        }
        let selected = categories.compactMap { types[$0] }.reduce(XCUIAccessibilityAuditType()) { $0.union($1) }
        do {
            try app.performAccessibilityAudit(for: selected) { issue in
                var captured = Amoo_AccessibilityInspectionIssue()
                captured.category = types.keys.sorted().filter { types[$0] == issue.auditType }.joined(separator: ",")
                if captured.category.isEmpty {
                    captured.category = String(issue.auditType.rawValue)
                }
                captured.description_p = String(issue.compactDescription.prefix(8192))
                captured.details = String(issue.detailedDescription.prefix(8192))
                result.truncated = result.truncated || issue.compactDescription.count > 8192
                    || issue.detailedDescription.count > 8192
                if let element = issue.element {
                    var info = Amoo_ElementInfo()
                    info.id = element.identifier
                    info.label = element.label
                    info.value = element.value as? String ?? ""
                    captured.element = info
                }
                if result.issues.count < 512 {
                    result.issues.append(captured)
                } else {
                    result.truncated = true
                }
                // Handle all findings so XCTest does not fail the persistent companion test.
                return true
            }
            result.status = result.issues.isEmpty ? "pass" : "fail"
            if app.state == .runningForeground, !isCancelled() {
                result.evaluatedChecks = categories
                result.notEvaluatedReasons = [:]
            } else {
                result.status = "executionError"
                result.error = "Audit cancelled or target app changed during capture."
            }
        } catch {
            result.error = String(describing: error)
        }
        return result
    }

    @available(iOS 27.0, *)
    private static func traverse(
        appID: String, phases: [Amoo_VoiceOverPhase], isCancelled: @escaping @Sendable () -> Bool
    ) -> Amoo_AccessibilityInspectionResponse {
        let journal: VoiceOverRecoveryJournal
        do { journal = try recoveryJournal }
        catch {
            return voiceOverResponse(AccessibilityInspection(
                status: "unsupported", provider: "appleVoiceOver",
                error: "Durable shared recovery storage is unavailable; VoiceOver was not changed."
            ))
        }
        let report = VoiceOverTraversal.run(
            appID: appID, phases: phases.map { .init(steps: Int($0.steps), direction: $0.direction) },
            service: XCTestVoiceOverControl(), journal: journal,
            isTargetForeground: { XCUIApplication(bundleIdentifier: appID).state == .runningForeground },
            isCancelled: isCancelled
        )
        return voiceOverResponse(report)
    }
}
