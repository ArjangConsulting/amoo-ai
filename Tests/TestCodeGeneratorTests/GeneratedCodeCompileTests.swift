import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Real-compiles generated test source with the actual toolchains (swiftc against the iOS
/// Simulator SDK; kotlinc against a resolved Espresso/JUnit/Hamcrest classpath), rather than
/// only asserting on substrings the way `TestCodeGeneratorTests` does. This is what actually
/// catches invalid output — three real bugs (an invalid Espresso `pressBack()` call, a
/// digit-leading class/method name, and an unescaped control character in a string literal)
/// slipped past the substring-based tests and were only caught by this tier.
final class GeneratedCodeCompileTests: XCTestCase {
    /// One operation per supported tool, plus the specific inputs that broke earlier: a name
    /// starting with a digit and text containing a newline/tab.
    private static let allToolOperations: [StudioToolOperation] = [
        .init(id: "op-1", tool: "tap_element", arguments: ["id": "email-field"]),
        .init(id: "op-2", tool: "set_text", arguments: ["id": "email-field", "value": "user@example.com"]),
        .init(id: "op-3", tool: "type_text", arguments: ["text": "line one\nline two\ttabbed"]),
        .init(id: "op-4", tool: "swipe_in_direction", arguments: ["direction": "up", "element_id": "list"]),
        .init(id: "op-5", tool: "wait_for_element", arguments: ["id": "spinner", "timeout_ms": "2000"]),
        // scroll followed by a targeted step -> performScrollToNode path.
        .init(id: "op-6", tool: "scroll", arguments: ["direction": "down"]),
        .init(id: "op-7", tool: "assert_visible", arguments: ["label": "Welcome"]),
        .init(id: "op-8", tool: "assert_not_visible", arguments: ["id": "spinner"]),
        .init(id: "op-9", tool: "assert_text", arguments: ["id": "greeting", "value": "Hi there"]),
        .init(id: "op-9b", tool: "assert_value", arguments: ["id": "email-field", "value": "user@example.com"]),
        .init(id: "op-10", tool: "take_screenshot", arguments: [:]),
        .init(id: "op-11", tool: "press_back", arguments: [:]),
        .init(id: "op-12", tool: "assert_enabled", arguments: ["id": "submit-button"]),
        // trailing scroll with no following target -> scrollByViewport fallback path.
        .init(id: "op-13", tool: "scroll", arguments: ["direction": "down", "distance": "400"])
    ]

    private func makeTest(platform: Platform) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "2FA Sign In Flow",
            description: "",
            platform: platform,
            steps: [.init(id: "step-1", instruction: "Sign in", expected: "Home screen appears")],
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: Self.allToolOperations)
        )
    }

    func testGeneratedXCUITestCompiles() throws {
        let result = try XCUITestEmitter().generate(makeTest(platform: .ios))
        try CompileVerification.verifySwiftCompiles(result.source)
    }

    func testGeneratedEspressoTestCompiles() throws {
        let result = try EspressoEmitter().generate(makeTest(platform: .android))
        try CompileVerification.verifyKotlinCompiles(result.source)
    }

    func testGeneratedComposeEspressoTestCompiles() throws {
        let result = try ComposeEspressoEmitter().generate(makeTest(platform: .android))
        try CompileVerification.verifyKotlinCompiles(result.source)
    }

    /// Picks among duplicate matches (`index` / `first`) on every targeting step.
    private static let pickOperations: [StudioToolOperation] = [
        .init(id: "p1", tool: "tap_element", arguments: ["id": "tab.reports", "index": "1"]),
        .init(id: "p2", tool: "assert_visible", arguments: ["label": "Reports", "first": "true"]),
        .init(id: "p3", tool: "tap_element", arguments: ["contains_text": "Rep", "index": "0"]),
        // A substring value check, beside an exact one.
        .init(id: "p4", tool: "assert_value", arguments: ["id": "greeting", "contains": "Hi"]),
        .init(id: "p5", tool: "assert_value", arguments: ["id": "greeting", "value": "Hi there"])
    ]

    private func makePickTest(platform: Platform) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Pick Flow",
            description: "",
            platform: platform,
            steps: [.init(id: "step-1", instruction: "Tap", expected: "Tapped")],
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: Self.pickOperations)
        )
    }

    func testGeneratedXCUITestWithAnIdiomGuardCompiles() throws {
        var test = makePickTest(platform: .ios)
        test = StudioAuthoredTest(
            formatVersion: test.formatVersion,
            name: test.name,
            description: test.description,
            platform: .ios,
            steps: test.steps,
            testContext: StudioTestContext(requiredIdiom: .pad),
            compiledPlan: test.compiledPlan
        )
        let result = try XCUITestEmitter().generate(test)
        try CompileVerification.verifySwiftCompiles(result.source)
    }

    func testGeneratedXCUITestPicksAndSubstringValueCompile() throws {
        let result = try XCUITestEmitter().generate(makePickTest(platform: .ios))
        XCTAssertTrue(result.source.contains(".contains(\"Hi\")"), result.source)
        try CompileVerification.verifySwiftCompiles(result.source)
    }

    func testGeneratedEspressoPicksCompile() throws {
        let result = try EspressoEmitter().generate(makePickTest(platform: .android))
        XCTAssertTrue(result.source.contains("private fun withIndex("), "the helper accompanies its use")
        try CompileVerification.verifyKotlinCompiles(result.source)
    }

    func testGeneratedComposePicksCompile() throws {
        let result = try ComposeEspressoEmitter().generate(makePickTest(platform: .android))
        try CompileVerification.verifyKotlinCompiles(result.source)
    }
}
