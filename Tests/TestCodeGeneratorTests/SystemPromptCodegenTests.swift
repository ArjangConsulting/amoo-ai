import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// A flow that asked amoo to answer system prompts (`dismiss_system_dialogs`) generates a test that
/// answers "Save Password?" the same way, so it does not depend on the simulator's AutoFill setting.
final class SystemPromptCodegenTests: XCTestCase {
    private func makeTest(platform: Platform = .ios, answering: Bool, context: StudioTestContext? = nil)
        -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Sign In",
            description: "",
            platform: platform,
            steps: [.init(id: "step-1", instruction: "Sign in", expected: "Home")],
            testContext: context,
            compiledPlan: .init(compiler: "session-compiler", compilerVersion: "1", toolOperations: [
                .init(id: "op-1", tool: "tap_element", arguments: ["id": "sign_in.submit"]),
                .init(id: "op-2", tool: "assert_visible", arguments: ["id": "home.title"]),
                .init(id: "op-3", tool: "assert_not_visible", arguments: ["id": "sign_in.submit"])
            ])
        ).answeringSystemDialogs(answering)
    }

    func testWaitsAnswerThePromptAndCompileWithoutWarnings() throws {
        let source = try XCUITestEmitter().generate(makeTest(answering: true)).source

        XCTAssertTrue(source.contains("private func answerSystemPasswordPrompt() -> Bool {"), source)
        XCTAssertTrue(source.contains(#"XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")"#), source)
        XCTAssertFalse(source.contains(#"buttons["Save"]"#), "never presses Save")
        for condition in [
            "element.waitForExistence(timeout: timeout ?? defaultTimeout)",
            "element.wait(for: \\.isHittable, toEqual: true, timeout: timeout ?? defaultTimeout)",
            "element.wait(for: \\.exists, toEqual: false, timeout: timeout ?? defaultTimeout)"
        ] {
            XCTAssertTrue(source.contains("waitAnsweringSystemPrompt { \(condition) },"), "\(condition)\n\(source)")
        }
        try CompileVerification.verifySwiftCompiles(source, swiftVersion: 6, extraArguments: ["-warnings-as-errors"])
    }

    func testATestWhoseFlowDidNotAskIsUnchanged() throws {
        let plain = try XCUITestEmitter().generate(makeTest(answering: false)).source
        XCTAssertFalse(plain.contains("answerSystemPasswordPrompt"), plain)
        XCTAssertFalse(plain.contains("waitAnsweringSystemPrompt"), plain)
    }

    func testTestCommonsWaitsArePrecededByOneThatAnswers() throws {
        let context = StudioTestContext(imports: ["TestCommonsXCUI"])
        let source = try XCUITestEmitter().generate(makeTest(answering: true, context: context)).source

        let preWait = "_ = waitAnsweringSystemPrompt { element.waitForExistence(timeout: timeout ?? defaultTimeout) }"
        XCTAssertTrue(source.contains("        \(preWait)\n        TestCommonsXCUI.waitForExistence(\n"), source)
    }
}
