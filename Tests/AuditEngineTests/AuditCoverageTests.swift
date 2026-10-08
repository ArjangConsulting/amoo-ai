// SwiftFormat compact wrapping conflicts with argument layout lint.
import AmooCore
import AuditEngine
import XCTest

private struct ConcernRule: AuditRule {
    let metadata = AuditRuleMetadata(
        id: "CONCERN",
        title: "Concern",
        domain: .ux,
        defaultSeverity: .high,
        references: []
    )
    func evaluate(_: AuditInput) async throws -> [AuditFinding] {
        [.init(
            id: "concern",
            ruleID: metadata.id,
            severity: .high,
            confidence: 0.2,
            summary: "Potential concern",
            remediation: "Review",
            evidence: [],
            tags: []
        )]
    }
}

private struct FailingRule: AuditRule {
    let metadata = AuditRuleMetadata(id: "ERROR", title: "Failure", domain: .ux, defaultSeverity: .high, references: [])
    func evaluate(_: AuditInput) async throws -> [AuditFinding] {
        throw CancellationError()
    }
}

final class AuditCoverageTests: XCTestCase {
    func testEmptyAndMissingGeometryCannotSupplyCompleteCoverage() async throws {
        let empty = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "placeholder")
        )
        let report = try await AuditEngine(rules: RulePacks.all).run(empty)
        XCTAssertTrue(report.evaluations.allSatisfy { $0.status == .insufficientEvidence })
        let partial = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            interactableElements: [
                .init(
                    id: "small",
                    label: "Small",
                    type: .button,
                    frame: .init(x: 0, y: 0, width: 10, height: 10)
                ),
                .init(id: "missing", label: "Missing", type: .button)
            ],
            geometryUnit: "points"
        )
        let sizes = try await AuditEngine(rules: [SmallTapTargetRule()]).run(partial)
        XCTAssertEqual(sizes.evaluations.first?.status, .insufficientEvidence)
        XCTAssertEqual(sizes.findings.count, 1, "Known concerns must survive incomplete coverage")
    }

    func testUnnormalizedPixelsCannotGenerateTapSizeConcerns() async throws {
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            interactableElements: [.init(
                id: "button",
                label: "Button",
                type: .button,
                frame: .init(x: 0, y: 0, width: 10, height: 10)
            )],
            geometryUnit: "pixels"
        )
        let report = try await AuditEngine(rules: [SmallTapTargetRule()]).run(input)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertEqual(report.evaluations.first?.status, .insufficientEvidence)
    }

    func testRuleFailurePreservesEarlierConcernsAndIndependentCoverage() async throws {
        let input = AuditInput(appID: "com.test", screenContext: .init(summary: ""), hierarchy: .init(id: "root"))
        let report = try await AuditEngine(rules: [ConcernRule(), FailingRule(), DeepLinkValidationRule()]).run(input)
        XCTAssertTrue(report.executionFailed)
        XCTAssertEqual(
            report.evaluations.map(\.status),
            [.insufficientEvidence, .executionError, .insufficientEvidence]
        )
        XCTAssertEqual(report.findings.first?.severity, .high)
        XCTAssertEqual(report.findings.first?.confidence, 0.2)
    }

    func testUnstableCaptureKeepsConcernsWithoutCleanCoverage() async throws {
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            evidenceProblems: ["Target changed during capture"]
        )
        let report = try await AuditEngine(rules: [ConcernRule()]).run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.evaluations.first?.status, .insufficientEvidence)
    }
}
