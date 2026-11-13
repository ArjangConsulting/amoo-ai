import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// The opt-in KotlinTestCommons mode of the Android emitters: the shared helpers are imported
/// instead of pasted into every generated test, mirroring `XCUITestContextTests` for TestCommonsXCUI.
final class AndroidTestCommonsTests: XCTestCase {
    private let deviceImport = "io.github.maniramezan.testcommons.device.*"
    private let composeImport = "io.github.maniramezan.testcommons.compose.*"

    private func makeTest(
        operations: [StudioToolOperation],
        context: StudioTestContext? = nil
    ) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Sign In Flow",
            description: "",
            platform: .android,
            steps: [.init(id: "step-1", instruction: "Sign in", expected: "Home screen appears")],
            testContext: context,
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: operations)
        )
    }

    private let viewOperations: [StudioToolOperation] = [
        .init(id: "1", tool: "tap_element", arguments: ["id": "submit", "index": "1"]),
        .init(id: "2", tool: "assert_not_visible", arguments: ["id": "spinner"]),
        .init(id: "3", tool: "assert_visible", arguments: ["label": "Welcome"])
    ]

    private let composeOperations: [StudioToolOperation] = [
        .init(id: "1", tool: "tap_element", arguments: ["id": "submit"]),
        .init(id: "2", tool: "scroll", arguments: ["direction": "down"]),
        .init(id: "3", tool: "assert_visible", arguments: ["id": "footer"]),
        .init(id: "4", tool: "scroll", arguments: ["direction": "down"]),
        .init(id: "5", tool: "assert_not_visible", arguments: ["id": "spinner"])
    ]

    func testEspressoSharedHelpersAreOptIn() throws {
        let test = makeTest(operations: viewOperations)

        let standalone = try EspressoEmitter().generate(test).source
        XCTAssertFalse(standalone.contains("testcommons"))
        XCTAssertTrue(standalone.contains("private fun waitUntil("))
        XCTAssertTrue(standalone.contains("private fun hasResourceEntryName("))
        XCTAssertTrue(standalone.contains("private fun withIndex("))

        let shared = try EspressoEmitter(useTestCommons: true).generate(test).source
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.device.waitUntilDisplayed"))
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.device.waitUntilNotDisplayed"))
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.device.hasResourceEntryName"))
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.device.withIndex"))
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.device.launchTargetApp"))
        XCTAssertTrue(shared.contains("launchTargetApp().use {"))
        XCTAssertTrue(shared.contains("        waitUntilNotDisplayed(anyOf("))
        XCTAssertFalse(shared.contains("onView(isRoot()).perform(waitUntil"))
        XCTAssertFalse(shared.contains("private fun "))
        XCTAssertFalse(shared.contains("ActivityScenario.launch"))
        XCTAssertFalse(shared.contains("TreeIterables"))
    }

    func testEspressoSharedImportsOnlyWhatTheBodyCalls() throws {
        let test = makeTest(operations: [.init(id: "1", tool: "wait_for_element", arguments: ["label": "Welcome"])])

        let shared = try EspressoEmitter(useTestCommons: true).generate(test).source

        XCTAssertTrue(shared.contains("testcommons.device.waitUntilDisplayed"))
        XCTAssertFalse(shared.contains("testcommons.device.withIndex"))
        XCTAssertFalse(shared.contains("testcommons.device.hasResourceEntryName"))
        XCTAssertFalse(shared.contains("testcommons.device.waitUntilNotDisplayed"))
    }

    func testEspressoContextImportOptsIn() throws {
        let context = StudioTestContext(imports: [deviceImport])

        let shared = try EspressoEmitter().generate(makeTest(operations: viewOperations, context: context)).source

        XCTAssertTrue(shared.contains("import \(deviceImport)"))
        XCTAssertTrue(shared.contains("launchTargetApp().use {"))
        XCTAssertFalse(shared.contains("private fun "))
    }

    func testEspressoSharedModeKeepsAppOwnedHelpersAndBaseClass() throws {
        let context = StudioTestContext(
            imports: [deviceImport, "com.example.support.AppUiTest"],
            baseClass: "AppUiTest()",
            helpers: [.init(name: "signIn", callTemplate: "signIn({{email}})")]
        )
        let test = makeTest(
            operations: [.init(id: "1", tool: "tap_element", arguments: ["email": "a@b.c"], helper: "signIn")],
            context: context
        )

        let shared = try EspressoEmitter().generate(test).source

        XCTAssertTrue(shared.contains("class SignInFlowTest : AppUiTest()"))
        XCTAssertTrue(shared.contains(#"signIn("a@b.c")"#))
        XCTAssertTrue(shared.contains("import com.example.support.AppUiTest"))
    }

    func testComposeSharedHelpersAreOptIn() throws {
        let test = makeTest(operations: composeOperations)

        let standalone = try ComposeEspressoEmitter().generate(test).source
        XCTAssertFalse(standalone.contains("testcommons"))
        XCTAssertTrue(standalone.contains("private fun scrollContainer("))
        XCTAssertTrue(standalone.contains("composeTestRule.waitUntil(timeoutMillis"))

        let shared = try ComposeEspressoEmitter(useTestCommons: true).generate(test).source
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.compose.scrollContainer"))
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.compose.scrollByViewport"))
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.compose.waitUntilDisplayed"))
        XCTAssertTrue(shared.contains("import io.github.maniramezan.testcommons.compose.waitUntilGone"))
        XCTAssertTrue(shared.contains("composeTestRule.scrollContainer(vertical = true).performScrollToNode("))
        XCTAssertTrue(shared.contains("composeTestRule.scrollByViewport(vertical = true, forward = true)"))
        XCTAssertTrue(shared
            .contains("composeTestRule.waitUntilDisplayed(hasTestTag(\"submit\"), timeoutMillis = 5000L)"))
        XCTAssertTrue(shared.contains("composeTestRule.waitUntilGone(hasTestTag(\"spinner\"), timeoutMillis = 5000L)"))
        XCTAssertFalse(shared.contains("private fun "))
        XCTAssertFalse(shared.contains("composeTestRule.waitUntil(timeoutMillis"))
        XCTAssertFalse(shared.contains("SemanticsActions"))
    }

    func testComposeContextImportOptsIn() throws {
        let context = StudioTestContext(imports: [composeImport])

        let shared = try ComposeEspressoEmitter()
            .generate(makeTest(operations: composeOperations, context: context)).source

        XCTAssertTrue(shared.contains("import \(composeImport)"))
        XCTAssertTrue(shared.contains("composeTestRule.scrollByViewport("))
        XCTAssertFalse(shared.contains("private fun "))
    }

    func testComposeSelectorsUseTheRepositoryTagCatalogAndKeepUnmappedTagsLiteral() throws {
        let context = StudioTestContext(
            imports: ["com.example.app.TestTags"],
            selectorExpressions: ["submit": "TestTags.Checkout.submit"]
        )

        let source = try ComposeEspressoEmitter()
            .generate(makeTest(operations: composeOperations, context: context)).source

        XCTAssertTrue(source.contains("import com.example.app.TestTags"))
        XCTAssertTrue(source.contains("hasTestTag(TestTags.Checkout.submit)"))
        XCTAssertFalse(source.contains("hasTestTag(\"submit\")"))
        XCTAssertTrue(source.contains("hasTestTag(\"spinner\")"))
        // The catalog is scoped to one emit; a later test without a context sees none of it.
        let standalone = try ComposeEspressoEmitter().generate(makeTest(operations: composeOperations)).source
        XCTAssertTrue(standalone.contains("hasTestTag(\"submit\")"))
    }

    func testTheDeviceImportDoesNotOptTheComposeEmitterIn() throws {
        let context = StudioTestContext(imports: [deviceImport])

        let source = try ComposeEspressoEmitter()
            .generate(makeTest(operations: composeOperations, context: context)).source

        XCTAssertTrue(source.contains("private fun scrollContainer("))
    }
}
