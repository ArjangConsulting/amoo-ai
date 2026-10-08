import Foundation
import XCTest

extension NativeAccessibilityInspector {
    static func authoredJourney(
        _ request: Amoo_AccessibilityInspectionRequest, isCancelled: @escaping @Sendable () -> Bool
    ) -> Amoo_AccessibilityInspectionResponse {
        do {
            guard request.journeyJson.utf8.count <= 131_072, request.phases.isEmpty else {
                throw AccessibilityJourneyValidationError()
            }
            let journey = try AccessibilityJourney.decodeJSON(request.journeyJson)
            try journey.validate()
            if #available(iOS 27.0, *) {
                let report = try AccessibilityJourneyRunner.run(
                    appID: request.appID, journey: journey,
                    service: XCTestAccessibilityJourneyControl(appID: request.appID), journal: recoveryJournal,
                    isTargetForeground: { XCUIApplication(bundleIdentifier: request.appID).state == .runningForeground
                    },
                    isCancelled: isCancelled
                )
                var response = voiceOverResponse(report)
                response
                    .journeyReportJson = try String(bytes: JSONEncoder().encode(report.journey), encoding: .utf8) ?? ""
                return response
            }
            return voiceOverResponse(.init(
                status: "unsupported",
                provider: "authoredAccessibilityJourney",
                error: "Requires iOS 27 public VoiceOver service"
            ))
        } catch {
            return voiceOverResponse(.init(
                status: "executionError",
                provider: "authoredAccessibilityJourney",
                error: "Journey validation or durable storage failed: \(error)"
            ))
        }
    }
}

@available(iOS 27.0, *)
@MainActor
private final class XCTestAccessibilityJourneyControl: AccessibilityJourneyControlling {
    let app: XCUIApplication
    let voiceOver = XCTestVoiceOverControl()

    init(appID: String) {
        app = XCUIApplication(bundleIdentifier: appID)
    }

    var isEnabled: Bool {
        voiceOver.isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        try voiceOver.setEnabled(enabled)
    }

    func move(direction: String) throws -> String {
        try voiceOver.move(direction: direction)
    }

    func currentSpeech() throws -> String {
        try XCUIDevice.shared.voiceOverService.currentSpeech().utterance
    }

    func elements(id: String) throws -> [AccessibilityElementEvidence] {
        // Capture one snapshot per exact match. Duplicate identifiers remain ambiguous.
        try app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex.prefix(2).map {
            let snapshot = try $0.snapshot()
            return AccessibilityElementEvidence(
                id: id, name: snapshot.label, role: snapshot.elementType.journeyRole,
                value: snapshot.value as? String, enabled: snapshot.isEnabled, selected: snapshot.isSelected
            )
        }
    }

    func perform(action: AccessibilityJourneyStep.Action, elementID: String) throws {
        let matches = app.descendants(matching: .any).matching(identifier: elementID)
        guard matches.count == 1, matches.element.isHittable else {
            throw NSError(
                domain: "amoo.journey",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Action requires one hittable target"]
            )
        }
        switch action {
        case .tap: matches.element.tap()
        case .doubleTap: matches.element.doubleTap()
        }
    }
}

private extension XCUIElement.ElementType {
    /// Do not use the automation type grouping, which folds links/checkboxes into buttons.
    var journeyRole: String? {
        switch self {
        case .button: "button"
        case .link: "link"
        case .checkBox: "checkBox"
        case .radioButton: "radioButton"
        case .staticText: "staticText"
        case .image: "image"
        case .textField: "textField"
        case .secureTextField: "secureTextField"
        case .switch: "switch"
        case .slider: "slider"
        case .picker: "picker"
        case .pickerWheel: "pickerWheel"
        case .cell: "cell"
        case .alert: "alert"
        case .sheet: "sheet"
        default: nil
        }
    }
}
