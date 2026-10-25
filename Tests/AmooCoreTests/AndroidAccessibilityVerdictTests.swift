// swiftlint:disable multiline_arguments
import AmooCore
import XCTest

final class AndroidAccessibilityVerdictTests: XCTestCase {
    func testATFErrorsFailButWarningsRequireReview() {
        let issue = AccessibilityInspection.Issue(
            category: "hitRegion", description: "Small target", details: "", elementID: "", label: "",
            semantics: ElementSemantics(attributes: ["resultType": "WARNING"])
        )
        var report = AccessibilityInspection(
            status: "observed", provider: "androidNativeATF", issues: [issue],
            requestedChecks: ["hitRegion"], evaluatedChecks: ["hitRegion"]
        )
        XCTAssertEqual(report.verdict, "notAssessed")
        report.issues[0].semantics?.attributes["resultType"] = "ERROR"
        XCTAssertEqual(report.verdict, "fail")
    }

    func testATFUnassessedCategoriesPreventACleanPass() {
        let report = AccessibilityInspection(
            status: "pass", provider: "androidNativeATF", requestedChecks: ["contrast", "hitRegion"],
            evaluatedChecks: ["hitRegion"], notEvaluatedReasons: ["contrast": "Rendering data unavailable"]
        )
        XCTAssertEqual(report.verdict, "notAssessed")
    }

    func testTalkBackSpeechVerdictRequiresQualifiedFocusAndMatchingCompleteEvidence() {
        var report = AccessibilityInspection(
            status: "pass", provider: "androidTalkBack", requestedChecks: ["talkBack.move.0"],
            evaluatedChecks: ["talkBack.move.0"],
            phases: [.init(
                phaseIndex: 0,
                direction: "forward",
                requestedSteps: 1,
                utterances: ["Receive updates", "Checkbox"]
            )],
            provenance: [
                "speech_expectations_json": "[{\"contains\":\"Receive updates\"}]",
                "restoration_status": "restored"
            ]
        )
        XCTAssertEqual(report.verdict, "pass")
        XCTAssertEqual(report.cleanupStatus, "restored")
        report.phases[0].utterances = ["Unrelated target"]
        XCTAssertEqual(report.verdict, "fail")
        report.evaluatedChecks = []
        XCTAssertEqual(report.verdict, "notAssessed")
        report.cleanupError = "Restoration failed"
        XCTAssertEqual(report.cleanupStatus, "failed")
    }
}

// swiftlint:enable multiline_arguments
