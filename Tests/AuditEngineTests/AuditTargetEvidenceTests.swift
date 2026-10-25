// swiftlint:disable multiline_arguments
import AmooCore
import AuditEngine
import XCTest

final class AuditTargetEvidenceTests: XCTestCase {
    private func input(_ elements: [ElementInfo]) -> AuditInput {
        AuditInput(
            appID: "com.test", screenContext: .init(summary: "Controls"), hierarchy: .init(id: "root"),
            interactableElements: elements, geometryUnit: "dp"
        )
    }

    func testAnonymousOccurrencesHaveDistinctCaptureReferencesAndGeometry() async throws {
        let capture = input([
            ElementInfo(id: "", label: "", type: .button, frame: Rect(x: 10, y: 20, width: 48, height: 48)),
            ElementInfo(id: "", label: "", type: .button, frame: Rect(x: 10, y: 90, width: 48, height: 48))
        ])
        let findings = try await MissingAccessibilityLabelRule().evaluate(capture)
        let evidence = try XCTUnwrap(findings.first).evidence
        XCTAssertEqual(evidence.count, 2)
        XCTAssertNotEqual(evidence[0].sourceRef, evidence[1].sourceRef)
        XCTAssertTrue(evidence.allSatisfy { $0.sourceRef.hasPrefix(capture.captureReference) })
        XCTAssertEqual(evidence[1].attributes["y"], "90.0")
        XCTAssertEqual(evidence[1].attributes["coordinateUnit"], "dp")
    }

    func testUncomputedAndroidNamesRequireReviewEvenWithEmptyOwnLabel() async throws {
        let capture = input([ElementInfo(
            id: "reset", label: "", type: .button,
            semantics: ElementSemantics(attributes: ["computedNameAvailability": "unavailable"])
        )])
        let rule = MissingAccessibilityLabelRule()
        let findings = try await rule.evaluate(capture)
        XCTAssertEqual(findings.first?.confidence, 0.4)
        XCTAssertEqual(findings.first?.severity, .low)
        XCTAssertEqual(rule.evidenceCoverage(capture).status, .insufficientEvidence)
    }

    func testClippedIntersectionDoesNotBecomeAnIntrinsicSmallTarget() async throws {
        let capture = input([ElementInfo(
            id: "header", label: "Header", type: .button,
            frame: Rect(x: 0, y: 0, width: 100, height: 2),
            semantics: ElementSemantics(attributes: ["clipping": "possible"])
        )])
        let rule = SmallTapTargetRule()
        let findings = try await rule.evaluate(capture)
        XCTAssertTrue(findings.isEmpty)
        XCTAssertEqual(rule.evidenceCoverage(capture).status, .insufficientEvidence)
    }

    func testKnownFullBoundsAreUsedInsteadOfVisibleIntersection() async throws {
        let capture = input([ElementInfo(
            id: "segment", label: "Dark", type: .button,
            frame: Rect(x: 0, y: 0, width: 48, height: 2),
            semantics: ElementSemantics(fullFrame: Rect(x: 0, y: -46, width: 48, height: 48))
        )])
        let findings = try await SmallTapTargetRule().evaluate(capture)
        XCTAssertTrue(findings.isEmpty)
    }
}

// swiftlint:enable multiline_arguments
