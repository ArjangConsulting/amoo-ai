@testable import CLI
import Foundation
import StudioProtocol
import TestCommons
import XCTest

/// A flow that asks amoo to answer system prompts records it in the plan, so the generated test
/// answers them too.
final class GeneratePlanSystemDialogTests: XCTestCase {
    private func plan(fromFlow json: String) throws -> StudioCompiledPlan? {
        let flow = try makeScratchDirectory().url.appending(path: "sign-in.amoo.json")
        try json.write(to: flow, atomically: true, encoding: .utf8)
        let out = try makeScratchDirectory().url
        let result = try runGeneratePlanCommand(options: GeneratePlanOptions(
            flowPath: flow.path,
            outputDirectory: out.path
        ))
        XCTAssertEqual(result.exitCode, 0, result.output)
        let data = try Data(contentsOf: out.appending(path: "plan.json"))
        return try JSONDecoder().decode(StudioAuthoredTest.self, from: data).compiledPlan
    }

    private func flow(top: String = "", step: String = "") -> String {
        """
        { "platform": "ios", \(top) "steps": [
          { "tool": "device_launch_app", "arguments": { "app_id": "com.example.app" } },
          { "tool": "tap_element", "arguments": { "id": "sign_in.submit" \(step) } } ] }
        """
    }

    func testTheFlowSwitchOrAStepArgumentIsRecorded() throws {
        XCTAssertEqual(try plan(fromFlow: flow(top: #""dismiss_system_dialogs": true,"#))?.dismissSystemDialogs, true)
        XCTAssertEqual(
            try plan(fromFlow: flow(step: #", "dismiss_system_dialogs": "true""#))?.dismissSystemDialogs,
            true
        )
    }

    func testAFlowThatDoesNotAskRecordsNothing() throws {
        let plan = try XCTUnwrap(plan(fromFlow: flow()))
        XCTAssertNil(plan.dismissSystemDialogs)
    }
}
