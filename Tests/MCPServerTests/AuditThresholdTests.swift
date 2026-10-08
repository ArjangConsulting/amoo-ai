// SwiftFormat compact wrapping conflicts with argument layout lint.
// swiftlint:disable multiline_arguments
import AuditEngine
import MCP
@testable import MCPServer
import XCTest

final class AuditThresholdTests: XCTestCase {
    func testEveryThresholdIncludesItsOwnSeverityAndAllHigherSeverities() async {
        let executor = DriverToolExecutor(driver: MockDriver())
        let severities: [Severity] = [.critical, .high, .medium, .low, .info]
        for (findingRank, severity) in severities.enumerated() {
            let finding = AuditFinding(
                id: "concern", ruleID: "rule", severity: severity, confidence: 0.5,
                summary: "Concern", remediation: "Review", evidence: [], tags: []
            )
            let report = AuditReport(
                appID: "com.test", findings: [finding],
                evaluations: [.init(ruleID: "rule", status: .evaluated, reason: "Complete fixture evidence")]
            )
            for (thresholdRank, threshold) in severities.enumerated() {
                let result = await executor.formatAuditReport(report, failOn: threshold.rawValue)
                let shouldFail = findingRank <= thresholdRank
                XCTAssertEqual(result.isError, shouldFail, "\(severity) at fail_on=\(threshold)")
                XCTAssertEqual(result.structuredContent?.objectValue?["verdict"], .string(shouldFail ? "fail" : "pass"))
            }
        }
    }
}

// swiftlint:enable multiline_arguments
