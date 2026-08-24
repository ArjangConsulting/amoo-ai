import StudioProtocol
@testable import TestCodeGenerator
import XCTest

final class TestCodeGeneratorTests: XCTestCase {
    private func makeTest(
        name: String = "Sign In Flow",
        platform: String = "iOS",
        operations: [StudioToolOperation]
    ) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: name,
            description: "",
            platform: platform,
            steps: [.init(id: "step-1", instruction: "Sign in", expected: "Home screen appears")],
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: operations)
        )
    }

    // MARK: - XCUITestEmitter

    func testXCUITestEmitterGeneratesTapByID() throws {
        let test = makeTest(operations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "sign-in"])])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertEqual(result.fileName, "SignInFlowTest.swift")
        XCTAssertTrue(result.source.contains("final class SignInFlowTest: XCTestCase"))
        XCTAssertTrue(result.source.contains("func testSignInFlow() throws"))
        XCTAssertTrue(result.source.contains(#"app.descendants(matching: .any)["sign-in"].tap()"#))
    }

    func testXCUITestEmitterGeneratesSetTextTapThenType() throws {
        let test = makeTest(operations: [.init(
            id: "op-1",
            tool: "set_text",
            arguments: ["id": "email", "value": "user@example.com"]
        )])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains(#"app.descendants(matching: .any)["email"].tap()"#))
        XCTAssertTrue(result.source.contains(#"app.descendants(matching: .any)["email"].typeText("user@example.com")"#))
    }

    func testXCUITestEmitterUsesLabelPredicateWhenIDMissing() throws {
        let test = makeTest(operations: [.init(id: "op-1", tool: "tap_element", arguments: ["label": "Sign In"])])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains(#"NSPredicate(format: "label == %@", "Sign In")"#))
    }

    func testXCUITestEmitterThrowsWhenNoCompiledPlan() {
        let test = StudioAuthoredTest(formatVersion: 1, name: "No Plan", description: "", platform: "iOS", steps: [])
        XCTAssertThrowsError(try XCUITestEmitter().generate(test)) { error in
            XCTAssertEqual(error as? TestCodeGeneratorError, .missingCompiledPlan)
        }
    }

    func testXCUITestEmitterThrowsWhenSetTextMissingValue() {
        let test = makeTest(operations: [.init(id: "op-1", tool: "set_text", arguments: ["id": "email"])])
        XCTAssertThrowsError(try XCUITestEmitter().generate(test)) { error in
            XCTAssertEqual(error as? TestCodeGeneratorError, .missingArgument(tool: "set_text", argument: "value"))
        }
    }

    func testXCUITestEmitterThrowsForUnknownTool() {
        let test = makeTest(operations: [.init(id: "op-1", tool: "not_a_real_tool", arguments: [:])])
        XCTAssertThrowsError(try XCUITestEmitter().generate(test)) { error in
            XCTAssertEqual(error as? TestCodeGeneratorError, .unsupportedTool("not_a_real_tool"))
        }
    }

    func testXCUITestEmitterGeneratesWaitAndAssertNotVisible() throws {
        let test = makeTest(operations: [
            .init(id: "op-1", tool: "wait_for_element", arguments: ["id": "spinner", "timeout_ms": "2000"]),
            .init(id: "op-2", tool: "assert_not_visible", arguments: ["id": "spinner"])
        ])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains("waitForExpectations(timeout: 2.0)"))
        XCTAssertTrue(result.source.contains(#"NSPredicate(format: "exists == false")"#))
    }

    // MARK: - EspressoEmitter

    func testEspressoEmitterGeneratesTapByID() throws {
        let test = makeTest(
            platform: "Android",
            operations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "sign-in"])]
        )
        let result = try EspressoEmitter().generate(test)

        XCTAssertEqual(result.fileName, "SignInFlowTest.kt")
        XCTAssertTrue(result.source.contains("class SignInFlowTest"))
        XCTAssertTrue(result.source.contains("fun signInFlow()"))
        XCTAssertTrue(result.source.contains(#"onView(hasResourceEntryName("sign-in")).perform(click())"#))
        XCTAssertTrue(result.source.contains("private fun hasResourceEntryName"))
    }

    func testEspressoEmitterOmitsResourceNameHelperWhenNoIDSelectorsUsed() throws {
        let test = makeTest(
            platform: "Android",
            operations: [.init(id: "op-1", tool: "tap_element", arguments: ["label": "Sign In"])]
        )
        let result = try EspressoEmitter().generate(test)

        XCTAssertTrue(result.source.contains(#"onView(withContentDescription("Sign In")).perform(click())"#))
        XCTAssertFalse(result.source.contains("private fun hasResourceEntryName"))
    }

    func testEspressoEmitterGeneratesSetTextReplaceText() throws {
        let test = makeTest(
            platform: "Android",
            operations: [.init(id: "op-1", tool: "set_text", arguments: ["id": "email", "value": "user@example.com"])]
        )
        let result = try EspressoEmitter().generate(test)

        XCTAssertTrue(result.source
            .contains(#"onView(hasResourceEntryName("email")).perform(replaceText("user@example.com"))"#))
    }

    func testEspressoEmitterThrowsForUnknownTool() {
        let test = makeTest(
            platform: "Android",
            operations: [.init(id: "op-1", tool: "not_a_real_tool", arguments: [:])]
        )
        XCTAssertThrowsError(try EspressoEmitter().generate(test)) { error in
            XCTAssertEqual(error as? TestCodeGeneratorError, .unsupportedTool("not_a_real_tool"))
        }
    }

    func testEspressoEmitterGeneratesValidPressBackCall() throws {
        let test = makeTest(platform: "Android", operations: [.init(id: "op-1", tool: "press_back", arguments: [:])])
        let result = try EspressoEmitter().generate(test)

        XCTAssertTrue(result.source.contains("import androidx.test.espresso.Espresso.pressBack"))
        XCTAssertTrue(result.source.contains("pressBack()"))
        XCTAssertFalse(result.source.contains("onView(isDisplayed()).perform(pressBack())"))
    }

    // MARK: - Identifier naming

    func testGeneratedIdentifiersDoNotStartWithADigit() throws {
        let iosTest = makeTest(
            name: "2FA Login",
            operations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "x"])]
        )
        let iosResult = try XCUITestEmitter().generate(iosTest)
        XCTAssertTrue(iosResult.source.contains("final class _2FALoginTest: XCTestCase"))
        XCTAssertTrue(iosResult.source.contains("func test_2FALogin() throws"))

        let androidTest = makeTest(
            name: "2FA Login",
            platform: "Android",
            operations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "x"])]
        )
        let androidResult = try EspressoEmitter().generate(androidTest)
        XCTAssertTrue(androidResult.source.contains("class _2FALoginTest"))
        XCTAssertTrue(androidResult.source.contains("fun _2FALogin()"))
    }

    // MARK: - Literal escaping

    func testXCUITestEmitterEscapesControlCharactersInStringLiterals() throws {
        let test = makeTest(operations: [.init(
            id: "op-1",
            tool: "type_text",
            arguments: ["text": "line one\nline two\ttabbed"]
        )])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains(#"app.typeText("line one\nline two\ttabbed")"#))
        XCTAssertFalse(result.source.contains("line one\nline two"))
    }

    func testEspressoEmitterEscapesControlCharactersInStringLiterals() throws {
        let test = makeTest(
            platform: "Android",
            operations: [.init(
                id: "op-1",
                tool: "set_text",
                arguments: ["id": "notes", "value": "line one\nline two\ttabbed"]
            )]
        )
        let result = try EspressoEmitter().generate(test)

        XCTAssertTrue(result.source.contains(#"replaceText("line one\nline two\ttabbed")"#))
    }
}
