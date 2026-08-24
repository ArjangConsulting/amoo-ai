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
        .init(id: "op-6", tool: "assert_visible", arguments: ["label": "Welcome"]),
        .init(id: "op-7", tool: "assert_not_visible", arguments: ["id": "spinner"]),
        .init(id: "op-8", tool: "assert_text", arguments: ["id": "greeting", "value": "Hi there"]),
        .init(id: "op-9", tool: "take_screenshot", arguments: [:]),
        .init(id: "op-10", tool: "press_back", arguments: [:])
    ]

    private func makeTest(platform: String) -> StudioAuthoredTest {
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
        let result = try XCUITestEmitter().generate(makeTest(platform: "iOS"))
        try CompileVerification.verifySwiftCompiles(result.source)
    }

    func testGeneratedEspressoTestCompiles() throws {
        let result = try EspressoEmitter().generate(makeTest(platform: "Android"))
        try CompileVerification.verifyKotlinCompiles(result.source)
    }
}
