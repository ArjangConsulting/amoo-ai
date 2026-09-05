import Foundation
@testable import MCPServer
import XCTest

final class MCPInstructionsAlignmentTests: XCTestCase {
    func testInstructionsAreBoundedAndDescribeAvailableTools() {
        let instructions = MCPStdioServer.instructions
        XCTAssertLessThan(instructions.utf8.count, 3500)
        for tool in [
            "start_session",
            "end_session",
            "find_elements",
            "assert_absent",
            "assert_visible",
            "swipe_in_direction",
            "compile_session_to_plan",
            "companion_warm",
            "companion_status"
        ] {
            XCTAssertTrue(MCPServer().toolNames().contains(tool))
            XCTAssertTrue(instructions.contains(tool))
        }
        XCTAssertTrue(instructions.contains("untrusted app data"))
        XCTAssertTrue(instructions.contains("inspection and debugging do not require test generation"))
    }

    func testDrivingSkillRoutesToExistingReferencesWithinContextBudget() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let skill = root.appendingPathComponent("skills/driving-amoo/SKILL.md")
        let text = try String(contentsOf: skill, encoding: .utf8)
        XCTAssertLessThan(text.split(separator: "\n").count, 150)
        for reference in ["coordinates.md", "recording.md"] {
            XCTAssertTrue(text.contains("references/\(reference)"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: skill.deletingLastPathComponent()
                    .appendingPathComponent("references/\(reference)").path))
        }
    }
}
