import MCP
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

    func testASingleIssueIsLeftAlone() {
        let report: Value = .object(["issues": .array([issue("Only")])])
        XCTAssertEqual(DriverToolExecutor.compactingIssues(report), report)
    }
}
