import AmooCore
import AuditEngine
import XCTest

private struct LowConfidenceRule: AuditRule {
    let metadata = AuditRuleMetadata(
        id: "TEST-LOW",
        title: "Low confidence finding",
        domain: .quality,
        defaultSeverity: .high,
        references: []
    )

    func evaluate(_: AuditInput) async throws -> [AuditFinding] {
        [
            AuditFinding(
                id: "finding-low",
                ruleID: metadata.id,
                severity: .high,
                confidence: 0.2,
                summary: "Low confidence",
                remediation: "Validate manually",
                evidence: [],
                tags: []
            )
        ]
    }
}

final class AuditEngineTests: XCTestCase {
    func testLowConfidenceDowngradesToInfo() async throws {
        let engine = AuditEngine(rules: [LowConfidenceRule()], lowConfidenceThreshold: 0.5)
        let report = try await engine.run(
            AuditInput(appID: "com.example.app", screenContext: .init(summary: "ok"), hierarchy: .init(id: "root"))
        )

        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].severity, .info)
    }

    // MARK: - Security Rules

    func testDebugBuildExposureDetectsDebugText() async throws {
        let engine = AuditEngine(rules: [DebugBuildExposureRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: "App running in Debug mode"),
            hierarchy: .init(id: "root")
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "SEC-001")
    }

    func testDebugBuildExposureIgnoresCleanContext() async throws {
        let engine = AuditEngine(rules: [DebugBuildExposureRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: "Production app running"),
            hierarchy: .init(id: "root")
        )
        let report = try await engine.run(input)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testInsecureTextFieldDetectsSensitiveFields() async throws {
        let engine = AuditEngine(rules: [InsecureTextFieldRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            elements: [
                ElementInfo(id: "pw-field", label: "Password", type: .textField),
                ElementInfo(id: "email-field", label: "Email", type: .textField)
            ]
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "SEC-002")
        XCTAssert(report.findings[0].summary.contains("Password"))
    }

    func testDeepLinkValidationDetectsWebViews() async throws {
        let engine = AuditEngine(rules: [DeepLinkValidationRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            elements: [
                ElementInfo(id: "wv-1", label: "WebContent", type: .webView)
            ]
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "SEC-003")
    }

    // MARK: - Quality Rules

    func testErrorStateHandlingDetectsMissingRetry() async throws {
        let engine = AuditEngine(rules: [ErrorStateHandlingRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            elements: [
                ElementInfo(id: "err", label: "Something went wrong", type: .staticText)
            ],
            interactableElements: [
                ElementInfo(id: "ok-btn", label: "OK", type: .button)
            ]
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "QA-001")
    }

    func testErrorStateHandlingPassesWithRetryButton() async throws {
        let engine = AuditEngine(rules: [ErrorStateHandlingRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            elements: [
                ElementInfo(id: "err", label: "Something went wrong", type: .staticText)
            ],
            interactableElements: [
                ElementInfo(id: "retry-btn", label: "Retry", type: .button)
            ]
        )
        let report = try await engine.run(input)
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testNavigationDeadEndDetectsNoInteractables() async throws {
        let engine = AuditEngine(rules: [NavigationDeadEndRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            interactableElements: []
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "QA-002")
    }

    func testNavigationDeadEndPassesWithNavBar() async throws {
        let engine = AuditEngine(rules: [NavigationDeadEndRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(
                id: "root",
                children: [ViewNode(id: "nav", type: .navigationBar)]
            ),
            interactableElements: []
        )
        let report = try await engine.run(input)
        XCTAssertTrue(report.findings.isEmpty)
    }

    // MARK: - UX Rules

    func testMissingAccessibilityLabelDetectsUnlabeledElements() async throws {
        let engine = AuditEngine(rules: [MissingAccessibilityLabelRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            interactableElements: [
                ElementInfo(id: "", label: "", type: .button),
                ElementInfo(id: "good-btn", label: "Submit", type: .button)
            ]
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "UX-001")
        XCTAssert(report.findings[0].summary.contains("1 interactable"))
    }

    func testSmallTapTargetDetectsSmallElements() async throws {
        let engine = AuditEngine(rules: [SmallTapTargetRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            interactableElements: [
                ElementInfo(id: "small", label: "X", type: .button, frame: Rect(x: 0, y: 0, width: 20, height: 20)),
                ElementInfo(id: "good", label: "OK", type: .button, frame: Rect(x: 0, y: 0, width: 44, height: 44))
            ]
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "UX-002")
    }

    // MARK: - Testability Rules

    func testMissingStableIdentifierDetectsNoIDs() async throws {
        let engine = AuditEngine(rules: [MissingStableIdentifierRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root"),
            interactableElements: [
                ElementInfo(id: "", label: "Submit", type: .button),
                ElementInfo(id: "", label: "Cancel", type: .button),
                ElementInfo(id: "ok-btn", label: "OK", type: .button)
            ]
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "TEST-001")
        XCTAssert(report.findings[0].summary.contains("2/3"))
    }

    func testHierarchyDepthDetectsDeepHierarchy() async throws {
        let engine = AuditEngine(rules: [HierarchyDepthRule()])
        // Create a hierarchy 20 levels deep
        var node = ViewNode(id: "leaf")
        for idx in (0 ..< 19).reversed() {
            node = ViewNode(id: "level-\(idx)", children: [node])
        }
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: node
        )
        let report = try await engine.run(input)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].ruleID, "TEST-002")
    }

    func testHierarchyDepthPassesForShallowHierarchy() async throws {
        let engine = AuditEngine(rules: [HierarchyDepthRule()])
        let input = AuditInput(
            appID: "com.test",
            screenContext: .init(summary: ""),
            hierarchy: .init(id: "root", children: [.init(id: "child")])
        )
        let report = try await engine.run(input)
        XCTAssertTrue(report.findings.isEmpty)
    }

    // MARK: - Rule Packs

    func testAllRulePacksReturnExpectedCounts() {
        XCTAssertEqual(RulePacks.security.count, 3)
        XCTAssertEqual(RulePacks.quality.count, 2)
        XCTAssertEqual(RulePacks.ux.count, 2)
        XCTAssertEqual(RulePacks.testability.count, 2)
        XCTAssertEqual(RulePacks.all.count, 9)
    }
}
