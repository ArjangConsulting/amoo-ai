// swiftlint:disable multiline_arguments
import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Real-compiles generated XCUITest source under Swift 6 and strict concurrency.
///
/// `XCUIApplication` and `XCUIElement` are main-actor isolated, so a generated `XCTestCase`
/// subclass that constructs the app in a property initializer, or forms `\.isHittable` /
/// `\.isSelected` key paths, only compiles when the class itself is isolated to `@MainActor`.
/// Without it a Swift 6 UI-test target rejects the file with "main actor-isolated default value in
/// a nonisolated context" and "cannot form key path to main actor-isolated property".
///
/// Set `AMOO_COMPILE_DEVELOPER_DIR` to another Xcode to repeat the check under its Swift version.
final class SwiftConcurrencyCompileTests: XCTestCase {
    private static let operations: [StudioToolOperation] = [
        .init(id: "op-1", tool: "tap_element", arguments: ["id": "email-field"]),
        .init(id: "op-2", tool: "set_text", arguments: ["id": "email-field", "value": "user@example.com"]),
        .init(id: "op-3", tool: "assert_visible", arguments: ["id": "day", "contains_text": "Range end"]),
        .init(id: "op-4", tool: "assert_selected", arguments: ["id": "day", "expected": "true"]),
        .init(id: "op-5", tool: "assert_selected", arguments: ["label": "Tuesday", "expected": "false"]),
        .init(id: "op-6", tool: "assert_enabled", arguments: ["id": "submit", "parent_id": "form"]),
        .init(id: "op-7", tool: "assert_not_visible", arguments: ["id": "spinner"]),
        .init(id: "op-8", tool: "take_screenshot", arguments: [:]),
        .init(id: "op-9", tool: "press_back", arguments: [:])
    ]

    private func makeTest(context: StudioTestContext? = nil) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Concurrency Flow",
            description: "",
            platform: .ios,
            steps: [.init(id: "step-1", instruction: "Tap", expected: "Tapped")],
            testContext: context,
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: Self.operations)
        )
    }

    private func generate(context: StudioTestContext? = nil) throws -> String {
        try XCUITestEmitter().generate(makeTest(context: context)).source
    }

    // MARK: - Default scaffold

    func testDefaultScaffoldCompilesUnderSwift6() throws {
        let source = try generate()
        XCTAssertTrue(source.contains("@MainActor\nfinal class ConcurrencyFlowTest: XCTestCase {"), source)
        try CompileVerification.verifySwiftCompiles(source, swiftVersion: 6)
    }

    func testDefaultScaffoldCompilesUnderCompleteStrictConcurrencyInSwift5Mode() throws {
        try CompileVerification.verifySwiftCompiles(
            generate(), swiftVersion: 5, extraArguments: ["-strict-concurrency=complete"]
        )
    }

    /// The negative control: the same source without its isolation reproduces both reported errors,
    /// so the passing tests above are evidence of the fix and not of a lenient compiler.
    func testWithoutMainActorTheReportedSwift6ErrorsReproduce() throws {
        let stripped = try generate().replacingOccurrences(of: "@MainActor\n", with: "")
        let result = try CompileVerification.swiftTypecheck(stripped, swiftVersion: 6)
        XCTAssertNotEqual(result.exitCode, 0, "an unisolated generated class must not compile under Swift 6")
        XCTAssertTrue(result.output.contains("main actor-isolated default value"), result.output)
        XCTAssertTrue(result.output.contains("cannot form key path to main actor-isolated property"), result.output)
    }

    func testSelectionHelperIsEmittedOnlyForTestsThatAssertSelection() throws {
        let withSelection = try generate()
        XCTAssertTrue(withSelection.contains("private func waitForSelection("))

        let plain = StudioAuthoredTest(
            formatVersion: 1, name: "Plain", description: "", platform: .ios,
            steps: [.init(id: "s", instruction: "Tap", expected: "Tapped")],
            compiledPlan: .init(
                compiler: "ai", compilerVersion: "1",
                toolOperations: [.init(id: "op", tool: "tap_element", arguments: ["id": "go"])]
            )
        )
        XCTAssertFalse(try XCUITestEmitter().generate(plain).source.contains("waitForSelection"))
    }

    // MARK: - App-owned contexts and custom base classes

    /// A Swift-defined base class that is not main-actor isolated and defines its own lifecycle,
    /// the shape of a hand-written `SampleUITestCase`.
    private static let nonisolatedBase = """

    class AppUITestCase: XCTestCase {
        override func setUpWithError() throws {
            continueAfterFailure = false
        }

        override func tearDownWithError() throws {}
    }

    @MainActor
    func makeTestApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)"]
        return app
    }
    """

    func testCustomNonisolatedBaseClassAndAppFactoryCompileUnderSwift6() throws {
        let context = StudioTestContext(
            baseClass: "AppUITestCase", appFactory: "makeTestApplication()", harnessLaunchesApp: true
        )
        let source = try generate(context: context)
        XCTAssertTrue(source.contains("@MainActor\nfinal class ConcurrencyFlowTest: AppUITestCase {"), source)
        try CompileVerification.verifySwiftCompiles(source + Self.nonisolatedBase, swiftVersion: 6)
        try CompileVerification.verifySwiftCompiles(
            source + Self.nonisolatedBase, swiftVersion: 5, extraArguments: ["-strict-concurrency=complete"]
        )
    }

    /// A base class that owns the app and is itself isolated to the main actor.
    private static let isolatedOwningBase = """

    @MainActor
    class OwningUITestCase: XCTestCase {
        var app: XCUIApplication!

        func makeApplication() -> XCUIApplication {
            XCUIApplication()
        }

        override func setUpWithError() throws {
            app = makeApplication()
            app.launch()
        }
    }
    """

    func testHarnessOwnedApplicationOnAnIsolatedBaseCompilesUnderSwift6() throws {
        let context = StudioTestContext(
            baseClass: "OwningUITestCase",
            harnessLaunchesApp: true,
            harnessOwnsApp: true,
            factoryOverride: "super.makeApplication()"
        )
        let source = try generate(context: context)
        XCTAssertEqual(source.components(separatedBy: "@MainActor").count - 1, 1, "isolated once, not twice")
        try CompileVerification.verifySwiftCompiles(source + Self.isolatedOwningBase, swiftVersion: 6)
    }

    func testIdLookupTemplateAndSelectorExpressionsCompileUnderSwift6() throws {
        let context = StudioTestContext(
            selectorExpressions: ["day": "AppID.day", "form": "AppID.form"],
            idLookupTemplate: "app.element(id: {{id}})"
        )
        let support = """

        enum AppID {
            static let day = "day"
            static let form = "form"
        }

        extension XCUIApplication {
            func element(id: String) -> XCUIElement {
                descendants(matching: .any)[id]
            }
        }
        """
        try CompileVerification.verifySwiftCompiles(generate(context: context) + support, swiftVersion: 6)
    }
}

// swiftlint:enable multiline_arguments
