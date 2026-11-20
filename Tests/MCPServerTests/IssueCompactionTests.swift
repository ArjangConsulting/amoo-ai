@testable import MCPServer
import XCTest

/// A native audit returned 13KB for 12 issues: each repeated the same provenance attributes, a
/// `fullFrame` equal to its `frame`, and empty hierarchy fields. These pin the lossless compaction.
final class IssueCompactionTests: XCTestCase {
    private static let shared: [String: Value] = [
        "provider": .string("XCUIAccessibilityAuditIssue.element"), "coordinateUnit": .string("points")
    ]

    private func issue(_ label: String, extra: [String: Value] = [:]) -> Value {
        let frame: Value = .object(["x": .int(1), "y": .int(2), "width": .int(3), "height": .int(4)])
        return .object([
            "category": .string("contrast"), "label": .string(label), "elementID": .string(""), "frame": frame,
            "semantics": .object([
                "attributes": .object(Self.shared.merging(extra) { _, new in new }),
                "fullFrame": frame, "hierarchyPath": .string(""), "reference": .string("ref-\(label)")
            ])
        ])
    }

    func testSharedAttributesMoveToTheReportAndDuplicatesAreDropped() throws {
        let report: Value = .object(["verdict": .string("fail"), "issues": .array([
            issue("Title"), issue("Subtitle", extra: ["boundsAvailability": .string("unavailable")])
        ])])
        let compacted = DriverToolExecutor.compactingIssues(report).objectValue
        XCTAssertEqual(compacted?["issueAttributes"], .object(Self.shared))
        let issues = try XCTUnwrap(compacted?["issues"]?.arrayValue)
        let first = try XCTUnwrap(issues.first?.objectValue)
        XCTAssertNil(first["elementID"], "empty strings dropped")
        let semantics = try XCTUnwrap(first["semantics"]?.objectValue)
        XCTAssertNil(semantics["attributes"], "no attributes of its own")
        XCTAssertNil(semantics["fullFrame"], "same as frame")
        XCTAssertNil(semantics["hierarchyPath"])
        XCTAssertEqual(semantics["reference"], .string("ref-Title"), "what differs is kept")
        let second = try XCTUnwrap(issues.last?.objectValue?["semantics"]?.objectValue)
        XCTAssertEqual(second["attributes"], .object(["boundsAvailability": .string("unavailable")]))
        XCTAssertEqual(compacted?["verdict"], .string("fail"))
    }

    /// Compact mode replaced every tool's text with "<tool>: ok"; for an audit that text is the
    /// grouped findings, so an agent had to read the structured report to learn them.
    func testCompactModeKeepsAnAuditsFindingsText() async {
        let executor = DriverToolExecutor(driver: MockDriver())
        let compact = ["response_mode": "compact"]
        let audit = ToolResult.success("2 issue(s)\n- contrast ×2: Low contrast", structuredContent: .object([:]))
        let compactAudit = await executor.compactResult(audit, tool: "audit_accessibility_native", arguments: compact)
        XCTAssertEqual(compactAudit.content, audit.content)
        let tap = ToolResult.success("Tapped", structuredContent: .object([:]))
        let compactTap = await executor.compactResult(tap, tool: "tap_element", arguments: compact)
        XCTAssertEqual(compactTap.content, "tap_element: ok")
    }

    func testASingleIssueIsLeftAlone() {
        let report: Value = .object(["issues": .array([issue("Only")])])
        XCTAssertEqual(DriverToolExecutor.compactingIssues(report), report)
    }

    func testFullAuditResponseKeepsAllIssueFields() {
        let report: Value = .object(["issues": .array([issue("Title"), issue("Subtitle")])])
        let result = ToolResult.success("2 issue(s)", structuredContent: report)
        let full = DriverToolExecutor.compactingIssueResponse(
            result, tool: "audit_accessibility_native", arguments: ["response_mode": "full"]
        )
        XCTAssertEqual(full.structuredContent, report)
        let compact = DriverToolExecutor.compactingIssueResponse(
            result,
            tool: "audit_accessibility_native",
            arguments: [:]
        )
        XCTAssertEqual(compact.structuredContent, DriverToolExecutor.compactingIssues(report))
    }
}
