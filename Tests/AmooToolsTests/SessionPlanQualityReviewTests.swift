import Foundation
import SessionCompiler
import TestSession
import XCTest

final class SessionPlanQualityReviewTests: XCTestCase {
    func testWarnsAboutUnverifiedCleanupAndVisibleCopy() {
        let warnings = SessionPlanQualityReview.warnings(for: [action("tap_element", ["label": "Sign out"])])
        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings.contains { $0.reason.contains("cleanup") })
    }

    func testWarnsWhenAbsentTargetWasNeverEstablished() {
        let warnings = SessionPlanQualityReview.warnings(for: [action("assert_absent", ["id": "app.row"])])
        XCTAssertEqual(warnings.count, 1)
    }

    func testVerifiedIdentifierBasedTransitionHasNoWarnings() {
        let warnings = SessionPlanQualityReview.warnings(for: [
            action("assert_visible", ["id": "app.row"]),
            action("tap_element", ["element_id": "app.delete"]),
            action("assert_absent", ["id": "app.row"])
        ])
        XCTAssertTrue(warnings.isEmpty)
    }

    private func action(_ tool: String, _ arguments: [String: String]) -> SessionAction {
        SessionAction(timestamp: Date(), toolName: tool, arguments: arguments, result: "ok", isError: false)
    }
}
