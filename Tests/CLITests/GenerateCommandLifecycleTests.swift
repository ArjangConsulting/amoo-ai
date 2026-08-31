@testable import CLI
import Foundation
import StudioProtocol
import TestCodeGenerator
import XCTest

/// Part 1: `amoo generate test` never emits an `XCTFail` for an amoo lifecycle / control-plane
/// call. Normal generation stops before writing a file when an app step is missing;
/// `--allow-incomplete` emits an `XCTFail` at that app step only.
final class GenerateCommandLifecycleTests: XCTestCase {
    private var emitters: StudioCodeEmitters {
        StudioCodeEmitters(ios: XCUITestEmitter(), android: EspressoEmitter())
    }

    private func writePlan(warnings: [StudioPlanWarning]) throws -> String {
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Sign In",
            description: "",
            platform: .ios,
            steps: [.init(id: "s1", instruction: "Tap submit", expected: "Signed in")],
            compiledPlan: .init(
                compiler: "session-compiler",
                compilerVersion: "1",
                toolOperations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "submit"])],
                warnings: warnings
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-\(UUID().uuidString).json")
        try JSONEncoder().encode(test).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testNormalGenerationFailsBeforeEmittingWhenAnAppStepIsMissing() throws {
        let path = try writePlan(warnings: [
            .init(kind: .excluded, actionIndex: 2, toolName: "tap", reason: "raw coordinate")
        ])

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil, allowIncomplete: false),
            emitters: emitters
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.output.contains("class SignInTest"), "no file/source should be emitted")
        XCTAssertTrue(result.output.contains("--allow-incomplete"))
    }

    func testAllowIncompleteFailsOnlyAtTheMissingAppStepNotForLifecycleCalls() throws {
        let path = try writePlan(warnings: [
            .init(kind: .excluded, actionIndex: 2, toolName: "tap", reason: "raw coordinate"),
            .init(kind: .notApplicable, actionIndex: 5, toolName: "compile_session_to_plan", reason: "control-plane")
        ])

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil, allowIncomplete: true),
            emitters: emitters
        )

        XCTAssertEqual(result.exitCode, 0)
        let failCount = result.output.components(separatedBy: "XCTFail(").count - 1
        XCTAssertEqual(failCount, 1, "exactly one XCTFail, at the missing app step")
        XCTAssertTrue(result.output.contains("XCTFail(\"Uncompiled required action 2 (tap):"))
        XCTAssertFalse(result.output.contains("compile_session_to_plan"))
    }
}
