@testable import CLI
import Foundation
import StudioProtocol
import TestCommons
import XCTest

// swiftlint:disable multiline_arguments

/// `amoo generate test` on a plan recorded against this Mac.
final class MacGenerateTests: XCTestCase {
    private func writePlan(platform: String) throws -> String {
        let flow = """
        {
          "platform": "\(platform)",
          "steps": [
            { "tool": "tap_element", "arguments": { "id": "new-note" } },
            { "tool": "scroll", "arguments": { "direction": "down" } },
            { "tool": "assert_visible", "arguments": { "id": "title" } }
          ]
        }
        """
        let directory = try makeScratchDirectory().url
        let flowURL = directory.appendingPathComponent("flow.amoo.json")
        try Data(flow.utf8).write(to: flowURL)
        let plan = try runGeneratePlanCommand(options: GeneratePlanOptions(
            flowPath: flowURL.path, outputDirectory: nil, contextPath: nil, testName: "Edit Note",
            testDescription: nil
        ))
        XCTAssertEqual(plan.exitCode, 0, plan.output)
        let planURL = directory.appendingPathComponent("plan.json")
        try Data(plan.output.utf8).write(to: planURL)
        return planURL.path
    }

    func testAMacPlanGeneratesAClickingXCUITest() throws {
        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: writePlan(platform: "macos"), outputDirectory: nil),
            emitters: CLIApp.makeCodeEmitters()
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("newNote.click()"), result.output)
        XCTAssertTrue(result.output.contains("scroll(byDeltaX: 0, deltaY: -300)"), result.output)
        XCTAssertFalse(result.output.contains(".tap()"), result.output)
    }

    func testAnIOSPlanStillGeneratesTouchInput() throws {
        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: writePlan(platform: "ios"), outputDirectory: nil),
            emitters: CLIApp.makeCodeEmitters()
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("newNote.tap()"), result.output)
        XCTAssertTrue(result.output.contains("app.swipeUp()"), result.output)
    }
}

// swiftlint:enable multiline_arguments
