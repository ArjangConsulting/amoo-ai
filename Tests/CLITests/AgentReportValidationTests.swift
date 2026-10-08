// SwiftFormat compact wrapping conflicts with argument layout lint.
import AmooCore
@testable import CLI
import Foundation
import XCTest

final class AgentReportValidationTests: XCTestCase {
    private let runID = "6E0628A0-797A-4620-B522-FAC15C9CC7F4"

    private func fixture(evidence: String) -> [String: Any] {
        [
            "schemaVersion": 2, "runID": runID, "status": "pass", "execution": "succeeded",
            "verdict": "pass", "cleanup": "released", "summary": "Login enabled",
            "provenance": [
                "app_id": "com.test",
                "app_build": "artifact-sha256",
                "device_id": "sim",
                "device_os": "27",
                "locale": "en",
                "host_binary": "/tmp/amoo",
                "host_version": "0.1", "host_sha256": String(repeating: "a", count: 64)
            ],
            "assertions": [["check": "login", "outcome": "pass", "evidence": [evidence]]],
            "coverage": ["requested": ["login"], "evaluated": ["login"], "notEvaluated": [:], "truncated": false],
            "artifacts": [[
                "path": evidence,
                "sha256": sha256Hex(ofRegularFile: evidence) ?? "",
                "runID": runID,
                "checks": ["login"]
            ]]
        ]
    }

    private func validate(_ report: [String: Any], extra: [String] = []) throws -> CLIResult {
        let scratch = try makeScratchDirectory()
        let path = scratch.url.appending(path: "compact.json")
        try JSONSerialization.data(withJSONObject: report).write(to: path)
        return runAgentReportValidation(["--report", path.path, "--run-id", runID, "--checks", "login"] + extra)
    }

    func testCompletePassAndCallerRequirementMatching() throws {
        let scratch = try makeScratchDirectory()
        let evidence = scratch.url.appending(path: "evidence.json")
        try Data("{}".utf8).write(to: evidence)
        let report = fixture(evidence: evidence.path)
        XCTAssertEqual(try validate(report).exitCode, 0)
        var wrongRun = report
        wrongRun["runID"] = UUID().uuidString
        XCTAssertEqual(try validate(wrongRun).exitCode, 1)
        var wrongCheck = report
        wrongCheck["coverage"] = [
            "requested": ["other"],
            "evaluated": ["other"],
            "notEvaluated": [:],
            "truncated": false
        ]
        XCTAssertEqual(try validate(wrongCheck).exitCode, 1)
    }

    func testExecutionAndSpeechCaptureCannotSubstituteForAssertionsCoverageOrCleanup() throws {
        let scratch = try makeScratchDirectory()
        let evidence = scratch.url.appending(path: "speech.json")
        try Data("{}".utf8).write(to: evidence)
        let report = fixture(evidence: evidence.path)
        for override: [String: Any] in [
            ["assertions": []], ["verdict": "notAssessed"], ["cleanup": "unknown"], ["execution": "failed"],
            ["coverage": [
                "requested": ["login"],
                "evaluated": [],
                "notEvaluated": ["login": "speech only"],
                "truncated": false
            ]],
            ["coverage": ["requested": ["login"], "evaluated": ["login"], "notEvaluated": [:], "truncated": true]],
            ["schemaVersion": 1], ["artifacts": ["/missing/amoo/evidence.json"]],
            ["rawSpeech": "Unexpected parent transcript data"]
        ] {
            XCTAssertEqual(try validate(report.merging(override, uniquingKeysWith: { _, new in new })).exitCode, 1)
        }
    }

    func testSealedEvidenceRejectsTamperingDirectoryAndWrongScope() throws {
        let scratch = try makeScratchDirectory()
        let evidence = scratch.url.appending(path: "evidence.json")
        try Data("{}".utf8).write(to: evidence)
        let sealed = fixture(evidence: evidence.path)
        try Data("changed".utf8).write(to: evidence)
        XCTAssertEqual(try validate(sealed).exitCode, 1)
        XCTAssertEqual(try validate(fixture(evidence: scratch.url.path)).exitCode, 1)
        var wrongScope = fixture(evidence: evidence.path)
        wrongScope["artifacts"] = [[
            "path": evidence.path,
            "sha256": sha256Hex(ofRegularFile: evidence.path) ?? "",
            "runID": UUID().uuidString,
            "checks": ["other"]
        ]]
        XCTAssertEqual(try validate(wrongScope).exitCode, 1)
        var unknown = fixture(evidence: evidence.path)
        var provenance = try XCTUnwrap(unknown["provenance"] as? [String: String])
        provenance["app_build"] = "unknown"
        unknown["provenance"] = provenance
        XCTAssertEqual(try validate(unknown).exitCode, 1)
    }

    func testCallerContextIsMandatoryAndJSONErrorsStayStructured() throws {
        let scratch = try makeScratchDirectory()
        let report = scratch.url.appending(path: "report.json")
        try JSONSerialization.data(withJSONObject: fixture(evidence: report.path)).write(to: report)
        let omitted = runAgentReportValidation(["--report", report.path, "--json"])
        XCTAssertEqual(omitted.exitCode, 1)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(omitted.output.utf8)) as? [String: Bool], nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(omitted.output.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        try Data("malformed".utf8).write(to: report)
        let malformed = runAgentReportValidation([
            "--report",
            report.path,
            "--run-id",
            runID,
            "--checks",
            "login",
            "--json"
        ])
        XCTAssertEqual(malformed.exitCode, 1)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(malformed.output.utf8)))
    }
}
