@testable import AmooCore
@testable import CLI
import Foundation
import XCTest

/// A subagent's report once carried prose in its digest fields ("see host_sha256 computed at report
/// time"). They hold a digest or say unknown, on every report, and amoo prints the values to copy.
final class AgentReportProvenanceTests: XCTestCase {
    func testDigestFieldsRejectProseOnAnyReport() {
        let prose = ["host_sha256": "see host_sha256 computed at report time (shasum -a 256 of the host binary)"]
        XCTAssertEqual(AgentRunReport.provenanceDigestErrors(prose).count, 1)
        let companion = ["companion_fingerprint": "the companion that env up installed"]
        XCTAssertEqual(AgentRunReport.provenanceDigestErrors(companion).count, 1)
    }

    func testDigestsCommitsAndUnknownAreAccepted() {
        let accepted = [
            "host_sha256": String(repeating: "a", count: 64),
            "companion_fingerprint": "402e1fb0a1b2c3d4e5f60718293a4b5c6d7e8f90-dirty"
        ]
        XCTAssertTrue(AgentRunReport.provenanceDigestErrors(accepted).isEmpty)
        let unknown = ["host_sha256": "unknown", "companion_fingerprint": "unavailable: reused a running companion"]
        XCTAssertTrue(AgentRunReport.provenanceDigestErrors(unknown).isEmpty)
    }

    func testVersionJSONUsesTheReportKeys() throws {
        let info = AmooBuildInfo(
            version: "0.4.0",
            executablePath: "/opt/amoo",
            binaryModifiedAt: nil,
            sourceCommit: "abc123",
            startedAt: Date(),
            pid: 1,
            binarySHA256: String(repeating: "b", count: 64)
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(CLIApp.versionJSON(info).utf8)) as? [String: String]
        )
        XCTAssertEqual(json["host_sha256"], String(repeating: "b", count: 64))
        XCTAssertEqual(json["host_binary"], "/opt/amoo")
        XCTAssertEqual(json["host_version"], "0.4.0 (abc123)")
    }
}
