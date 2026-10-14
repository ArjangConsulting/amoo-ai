// swiftlint:disable multiline_arguments
import StudioProtocol
import TestCodeGenerator
import XCTest

final class HarnessOwnershipTests: XCTestCase {
    func testHarnessOwnedAppUsesFactoryAndInheritedWaitWithoutShadowing() throws {
        let context = StudioTestContext(
            imports: ["JotUIIdentifiers"], baseClass: "JotUITestCase", harnessLaunchesApp: true,
            selectorExpressions: ["habits": "JotUIAutomationID.Tab.habits"],
            idLookupTemplate: "app.element(id: {{id}})", harnessOwnsApp: true,
            factoryOverride: "super.makeApplication().usingLanguage(\"en\", locale: \"en_US\")",
            waitBindings: ["waitForHittability": "waitForExistence({{element}})"],
            timeoutExpressions: ["default": "UITestConstants.timeout"]
        )
        let test = StudioAuthoredTest(
            formatVersion: 1, name: "Habit Creation", description: "", platform: .ios,
            steps: [], testContext: context,
            compiledPlan: .init(compiler: "test", compilerVersion: "1", toolOperations: [
                .init(id: "1", tool: "tap_element", arguments: ["id": "habits"])
            ])
        )
        let source = try XCUITestEmitter().generate(test).source
        XCTAssertTrue(source.contains("@MainActor\nfinal class HabitCreationTest: JotUITestCase"))
        XCTAssertTrue(source.contains("override func makeApplication() -> XCUIApplication"))
        XCTAssertTrue(source.contains("super.makeApplication().usingLanguage(\"en\", locale: \"en_US\")"))
        XCTAssertTrue(source.contains("app.element(id: JotUIAutomationID.Tab.habits)"))
        XCTAssertFalse(source.contains("var app"))
        XCTAssertFalse(source.contains("app.launch()"))
        XCTAssertFalse(source.contains("private func waitForHittability"))
        XCTAssertTrue(source.contains("waitForExistence(habitsTab)"), source)
        let fixture = source.replacingOccurrences(of: "import JotUIIdentifiers\n", with: "") + """

        enum UITestConstants { static let timeout: TimeInterval = 5 }
        enum JotUIAutomationID {
            enum Tab { static let habits = "habits" }
        }
        @MainActor
        class JotUITestCase: XCTestCase {
            var app = XCUIApplication()
            func makeApplication() -> XCUIApplication { app }
            func waitForExistence(_ element: XCUIElement) {}
        }
        extension XCUIApplication {
            func element(id: String) -> XCUIElement { descendants(matching: .any)[id] }
            func usingLanguage(_ language: String, locale: String) -> XCUIApplication { self }
        }
        """
        try CompileVerification.verifySwiftCompiles(fixture, swiftVersion: 6)
    }

    func testRelaunchRequiresTheHarnessHelper() throws {
        let test = StudioAuthoredTest(
            formatVersion: 1, name: "Persistence", description: "", platform: .ios,
            steps: [], compiledPlan: .init(compiler: "test", compilerVersion: "1", toolOperations: [
                .init(id: "1", tool: "relaunch_application", arguments: [:])
            ])
        )
        XCTAssertThrowsError(try XCUITestEmitter().generate(test))
        let context = StudioTestContext(relaunchHelper: "relaunchApplication()")
        let source = try XCUITestEmitter().generate(test.replacingTestContext(context)).source
        XCTAssertTrue(source.contains("        relaunchApplication()"))
        XCTAssertFalse(source.contains("app.terminate()"))
    }

    func testAssertionBindingPreservesExpectedValueAndTimeoutConstant() throws {
        let test = StudioAuthoredTest(
            formatVersion: 1, name: "Assertions", description: "", platform: .ios,
            steps: [], compiledPlan: .init(compiler: "test", compilerVersion: "1", toolOperations: [
                .init(id: "1", tool: "assert_text", arguments: ["id": "title", "value": "A \"habit\""])
            ])
        )
        let context = StudioTestContext(
            timeoutExpressions: ["default": "UITestConstants.timeout"],
            assertionBindings: ["assert_text": "assertLabel({{element}}, equals: {{value}}, timeout: {{timeout}})"]
        )
        let source = try XCUITestEmitter().generate(test.replacingTestContext(context)).source
        XCTAssertTrue(source.contains("timeout: UITestConstants.timeout"))
        XCTAssertTrue(source.contains(#"equals: "A \"habit\"""#), source)
        let invalid = StudioTestContext(assertionBindings: ["assert_text": "assertVisible({{element}})"])
        XCTAssertThrowsError(try XCUITestEmitter().generate(test.replacingTestContext(invalid)))
    }

    func testLegacyContextRetainsEmitterOwnership() throws {
        let context = try JSONDecoder().decode(StudioTestContext.self, from: Data("{}".utf8))
        XCTAssertFalse(context.harnessOwnsApp)
        XCTAssertNil(context.factoryOverride)
        XCTAssertTrue(context.waitBindings.isEmpty)
    }
}

// swiftlint:enable multiline_arguments
