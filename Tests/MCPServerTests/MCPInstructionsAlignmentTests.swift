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
            "screenshot", // points-vs-pixels warning
            "assert_not_visible", // verify a delete
            "assert_visible", // verify an add
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

    func testInstructionsMentionDeterministicLaunchState() {
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("launch"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("setUp"))
    }
}
