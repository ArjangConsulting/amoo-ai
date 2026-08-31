import Foundation
@testable import MCPServer
import XCTest

/// Pins the MCP `initialize` instructions to the guidance the session compiler and code generator
/// actually implement, so the two cannot drift apart silently. The generator-output cross-check
/// lives in `IntegrationTests` (which can import `TestCodeGenerator`).
final class MCPInstructionsAlignmentTests: XCTestCase {
    private var instructions: String {
        MCPStdioServer.instructions
    }

    func testInstructionsCoverSemanticSelectorAndGestureGuidance() {
        for phrase in [
            "find_elements", // inspect before acting
            "accessibility id", // selector priority
            "swipe_in_direction", // semantic gesture tool
            "element_id", // canonical row-swipe: element-scoped, not coordinates
            "screenshot", // points-vs-pixels warning
            "assert_absent", // verify a delete — the exposed tool name, not assert_not_visible
            "assert_visible", // verify an add
            "end_session", // the exposed lifecycle tool name
            "compile_session_to_plan",
            "--allow-incomplete", // and why not to reach for it
            "UUID", // reject opaque-id variable names
            "--test-name", // descriptive test name
            "Report back" // report plan path / file / warnings
        ] {
            XCTAssertTrue(
                instructions.localizedCaseInsensitiveContains(phrase),
                "MCP instructions no longer mention '\(phrase)'"
            )
        }
    }

    func testInstructionsTreatIncompletePlanAsFailure() {
        XCTAssertTrue(instructions.contains("FAILED codegen result"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("incomplete-plan"))
    }

    func testInstructionsCiteTheElementScopedSwipeExample() {
        // The concrete example must stay verbatim so IntegrationTests can assert the generator
        // produces exactly this identifier for the documented input.
        XCTAssertTrue(instructions.contains("cigarettesHabitRow.swipeLeft()"))
    }

    func testInstructionsNameOnlyExposedToolsForAssertionsAndLifecycle() {
        // Part 4: instructions must not send agents at tool names that are not exposed.
        XCTAssertFalse(instructions.contains("assert_not_visible"))
        XCTAssertFalse(instructions.contains("end_test_session"))
        XCTAssertFalse(instructions.contains("start_test_session"))
    }

    func testInstructionsGiveOneCanonicalRowSwipeWorkflow() {
        // The canonical row swipe is element-scoped `swipe_in_direction`, with a coordinate
        // fallback — never "prefer coordinates".
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("canonical"))
        XCTAssertTrue(instructions.contains("`swipe_in_direction` with the row's `element_id`"))
        XCTAssertFalse(instructions.localizedCaseInsensitiveContains("prefer a coordinate"))
    }

    func testInstructionsMentionDeterministicLaunchState() {
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("launch"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("setUp"))
    }
}
