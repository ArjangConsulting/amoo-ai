// swiftlint:disable multiline_arguments
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

final class SessionReportSchemaTests: XCTestCase {
    /// The output schema forbids additional properties, so a `SessionReport` field it does not
    /// declare makes a schema-validating client reject an otherwise good report.
    func testEverySessionReportFieldIsDeclaredInTheOutputSchema() throws {
        let definition = try XCTUnwrap(MCPServer().toolDefinitions().first { $0.name == "get_session_report" })
        let declared = try Set(XCTUnwrap(definition.outputSchema).properties.keys)
        let report = SessionReport(
            sessionID: "s", appID: "a", deviceID: "d", platform: "ios", startedAt: Date(), endedAt: nil,
            durationSeconds: 0, actionCount: 0, errorCount: 0, isActive: true, actions: [],
            launchArguments: [], launchEnvironment: [:], testName: nil
        )
        let fields = Set(Mirror(reflecting: report).children.compactMap(\.label))
        let missing = fields.subtracting(declared).sorted()
        XCTAssertTrue(missing.isEmpty, "get_session_report output schema lacks: \(missing)")
    }
}

// swiftlint:enable multiline_arguments
