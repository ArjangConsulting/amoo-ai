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

    /// Part 1: the one canonical lifecycle is `start_session` → drive → `end_session` → inspect →
    /// generate, with `compile_session_to_plan` demoted to an optional preview. The instructions
    /// must not tell agents to run `compile_session_to_plan` as a step after `end_session`.
    func testInstructionsDescribeTheCanonicalLifecycleWorkflow() {
        XCTAssertTrue(instructions.contains("Canonical workflow: `start_session`"))
        XCTAssertTrue(instructions.contains("`end_session` (this already compiles"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("optional preview"))
        XCTAssertTrue(instructions.contains("it is never a required step"))
        // The redundant "end_session, then compile_session_to_plan" chain must be gone.
        XCTAssertFalse(instructions.contains("End, compile, and inspect"))
        XCTAssertFalse(instructions.localizedCaseInsensitiveContains(
            "`end_session`, then `compile_session_to_plan`"
        ))
        XCTAssertTrue(instructions.contains("you do not call `compile_session_to_plan` as a follow-up step"))
    }

    /// Part 1: lifecycle / control-plane calls never become app actions and never produce an
    /// uncompiled-action `XCTFail`.
    func testInstructionsStateLifecycleCallsNeverBecomeTestSteps() {
        XCTAssertTrue(instructions.contains(
            "are never recorded as app actions and never produce an `XCTFail` for uncompiled work"
        ))
    }

    // MARK: - Skill ↔ instructions drift (Part 5)

    private func skillMarkdown(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        // Tests/MCPServerTests/<this file>  ->  repo root is three levels up.
        let repoRoot = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = repoRoot.appendingPathComponent("skills/driving-amoo/SKILL.md")
        return try String(contentsOf: skill, encoding: .utf8)
    }

    /// The `driving-amoo` skill and the `initialize` instructions must describe the SAME canonical
    /// lifecycle and name only exposed tools, so an agent gets one story regardless of entry point.
    func testDrivingAmooSkillMatchesTheCanonicalWorkflowAndToolNames() throws {
        let skill = try skillMarkdown()

        // One canonical workflow, compile demoted to optional preview.
        XCTAssertTrue(skill.contains("**Canonical workflow:**"))
        XCTAssertTrue(skill.contains("`start_session`"))
        XCTAssertTrue(skill.contains("`end_session`"))
        XCTAssertTrue(skill.contains("`amoo generate test`"))
        XCTAssertTrue(skill.localizedCaseInsensitiveContains("optional"))
        XCTAssertTrue(skill.contains("never a required step"))

        // The redundant "end_session -> compile_session_to_plan -> inspect" chain must be gone.
        XCTAssertFalse(skill.contains("`end_session` → `compile_session_to_plan` → inspect"))
        XCTAssertFalse(skill.contains("End, compile, then read the warnings"))

        // Absence assertion: the exposed tool name only.
        XCTAssertTrue(skill.contains("assert_absent"))
        XCTAssertFalse(skill.contains("assert_not_visible"))
        XCTAssertFalse(skill.contains("end_test_session"))
        XCTAssertFalse(skill.contains("start_test_session"))

        // Generated-test quality — not a green simulator session — is the objective.
        XCTAssertTrue(skill.localizedCaseInsensitiveContains("not the deliverable"))
    }
}
