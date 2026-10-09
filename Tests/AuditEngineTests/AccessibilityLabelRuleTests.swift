import AmooCore
import AuditEngine
import XCTest

final class AccessibilityLabelRuleTests: XCTestCase {
    private func findings(_ elements: [ElementInfo]) async throws -> [AuditFinding] {
        try await MissingAccessibilityLabelRule().evaluate(AuditInput(
            appID: "com.test",
            screenContext: .init(summary: "Form"),
            hierarchy: .init(id: "root"),
            interactableElements: elements
        ))
    }

    func testPlaceholderNamedInputIsALowSeverityConcernNotAMissingName() async throws {
        let results = try await findings([
            ElementInfo(id: "email", label: "", value: "Email", type: .textField, placeholder: "Email")
        ])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].severity, .low)
        XCTAssertTrue(results[0].summary.contains("named only by placeholder"))
        XCTAssertEqual(results[0].evidence.first?.sourceRef, "email")
    }

    func testInputWithoutPlaceholderReportIsUnconfirmedRatherThanMissing() async throws {
        // An older companion: on iOS an empty field's value is its placeholder.
        let results = try await findings([
            ElementInfo(id: "email", label: "", value: "Email", type: .textField)
        ])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].severity, .low)
        XCTAssertEqual(results[0].confidence, 0.4)
        XCTAssertTrue(results[0].summary.contains("could not be confirmed"))
    }

    func testInputWithNoNameSourceIsStillMissing() async throws {
        let results = try await findings([
            ElementInfo(id: "blank-reported", label: "", type: .textField, placeholder: " "),
            ElementInfo(id: "blank-unreported", label: "", type: .textField),
            ElementInfo(id: "icon", label: "", type: .button)
        ])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].severity, .medium)
        XCTAssertTrue(results[0].summary.contains("3 interactable"))
    }

    func testEvidenceIsBoundedWhileTheSummaryKeepsTheFullCount() async throws {
        let elements = (0 ..< 40).map { ElementInfo(id: "icon-\($0)", label: "", type: .button) }
        let results = try await findings(elements)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].summary.contains("40 interactable"))
        XCTAssertEqual(results[0].evidence.count, 25)
    }
}
