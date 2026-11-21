import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Compose exports that fit a repository's test target: only the imports they use, the recording's
/// launch environment, label matching on text or content description, and the harness's own hooks.
final class ComposeHarnessExportTests: XCTestCase {
    private func makeTest(
        requirements: StudioTestRequirements? = nil,
        context: StudioTestContext? = nil
    ) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Search",
            description: "",
            platform: .android,
            steps: [.init(id: "step-1", instruction: "Search", expected: "Results")],
            requirements: requirements,
            testContext: context,
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: operations())
        )
    }

    private func operations() -> [StudioToolOperation] {
        [
            .init(id: "op-1", tool: "assert_visible", arguments: ["id": "home.search"]),
            .init(id: "op-2", tool: "tap_element", arguments: ["id": "home.search"]),
            .init(id: "op-3", tool: "tap_element", arguments: ["label": "Practice"])
        ]
    }

    func testStandaloneExportImportsOnlyWhatItUsesAndCarriesTheLaunchEnvironment() throws {
        let test = makeTest(requirements: StudioTestRequirements(launchEnvironment: ["UI_TEST_PROFILE": "clean-home"]))
        let source = try ComposeEspressoEmitter().generate(test).source
        XCTAssertFalse(source.contains("androidx.test.espresso"), "unused Espresso imports break Compose-only targets")
        XCTAssertFalse(source.contains("import androidx.compose.ui.test.swipeUp"))
        XCTAssertTrue(source.contains(#"launchIntent.putExtra("UI_TEST_PROFILE", "clean-home")"#), source)
        XCTAssertTrue(source.contains(#"(hasText("Practice") or hasContentDescription("Practice"))"#), source)
        let waits = source.components(separatedBy: #"onAllNodes(hasTestTag("home.search"))"#).count - 1
        XCTAssertEqual(waits, 1, "the tap right after the assertion needs no second wait")
    }

    func testAHarnessContextSuppliesPackageAnnotationsRuleAndLauncher() throws {
        let test = makeTest(context: StudioTestContext(
            imports: ["com.example.support.AppUiTest"],
            baseClass: "AppUiTest()",
            harnessOwnsApp: true,
            kotlinPackage: "com.example.generated",
            classAnnotations: ["@MockedUiTest"],
            launchWrapper: "launchApp"
        ))
        let source = try ComposeEspressoEmitter().generate(test).source
        XCTAssertTrue(source.hasPrefix("package com.example.generated\n\n"), source)
        XCTAssertTrue(source.contains("@MockedUiTest\nclass "), source)
        XCTAssertFalse(source.contains("RunWith"), "the base class's runner is inherited")
        let imports = source.split(separator: "\n").filter { $0.hasPrefix("import ") }
        XCTAssertEqual(imports, imports.sorted(), "context imports sort into the block")
        XCTAssertTrue(source.contains("import com.example.support.AppUiTest\nimport org.junit."), source)
        XCTAssertTrue(source.contains(": AppUiTest() {\n    @Test"), source)
        XCTAssertFalse(source.contains("createEmptyComposeRule"), "the base class owns the rule")
        XCTAssertTrue(source.contains("        launchApp {\n"), source)
        XCTAssertFalse(source.contains("ActivityScenario"))
    }

    func testTheViewsEmitterAlsoCarriesTheLaunchEnvironment() throws {
        let test = makeTest(requirements: StudioTestRequirements(launchEnvironment: ["UI_TEST_PROFILE": "clean-home"]))
        let source = try EspressoEmitter().generate(test).source
        XCTAssertTrue(source.contains(#"launchIntent.putExtra("UI_TEST_PROFILE", "clean-home")"#), source)
    }
}
