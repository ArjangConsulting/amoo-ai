import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

final class TestCodeGeneratorTests: XCTestCase {
    private func makeTest(
        name: String = "Sign In Flow",
        platform: Platform = .ios,
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
        XCTAssertTrue(result.source.contains(#"let signIn = app.descendants(matching: .any)["sign-in"]"#))
        XCTAssertTrue(result.source.contains(#"waitForHittability(signIn, named: "signIn", timeout: 5.0)"#))
        XCTAssertTrue(result.source.contains("signIn.tap()"))
    }

    func testXCUITestEmitterGeneratesSetTextReplacement() throws {
        let test = makeTest(operations: [.init(
            id: "op-1",
            tool: "set_text",
            arguments: ["id": "email", "value": "user@example.com"]
        )])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains(#"let email = app.descendants(matching: .any)["email"]"#))
        XCTAssertTrue(result.source.contains(#"waitForHittability(email, named: "email", timeout: 5.0)"#))
        XCTAssertTrue(result.source.contains(#"replaceText(in: email, with: "user@example.com")"#))
        XCTAssertTrue(result.source.contains("XCUIKeyboardKey.delete.rawValue"))
    }

    func testXCUITestEmitterFailsFastAndAttachesDiagnostics() throws {
        let test = makeTest(operations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "submit"])])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains("continueAfterFailure = false"))
        XCTAssertTrue(result.source.contains("Failure screenshot"))
        XCTAssertTrue(result.source.contains("Failure UI hierarchy"))
    }

    func testXCUITestEmitterPrefersNavigationBackButton() throws {
        let test = makeTest(operations: [.init(id: "op-1", tool: "press_back", arguments: [:])])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains("let backButton = app.navigationBars.buttons.element(boundBy: 0)"))
        XCTAssertTrue(result.source.contains("backButton.tap()"))
        XCTAssertTrue(result.source.contains("app.swipeRight()"))
        XCTAssertTrue(result.source.contains("pressBack()"))
    }

    func testXCUITestEmitterUsesLabelPredicateWhenIDMissing() throws {
        let test = makeTest(operations: [.init(id: "op-1", tool: "tap_element", arguments: ["label": "Sign In"])])
        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains(#"NSPredicate(format: "label == %@", "Sign In")"#))
    }

    func testXCUITestEmitterThrowsWhenNoCompiledPlan() {
        let test = StudioAuthoredTest(formatVersion: 1, name: "No Plan", description: "", platform: .ios, steps: [])
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

        XCTAssertTrue(result.source.contains(#"waitForExistence(spinner, named: "spinner", timeout: 2.0)"#))
        XCTAssertTrue(result.source.contains(#"waitForNonHittability(spinner2, named: "spinner2", timeout: 5.0)"#))
        XCTAssertFalse(result.source.contains("waitForExpectations"))
    }

    func testXCUITestEmitterDerivesReadableNamesFromNamespacedIdentifiers() throws {
        let test = makeTest(operations: [.init(
            id: "step-0",
            tool: "tap_element",
            arguments: ["id": "sample.home.feed.sectionTitle.most_loved"]
        )])

        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains(
            #"let mostLovedSectionTitle = app.descendants(matching: .any)["sample.home.feed.sectionTitle.most_loved"]"#
        ))
        XCTAssertTrue(result.source.contains("mostLovedSectionTitle.tap()"))
        XCTAssertFalse(result.source.contains("element_step_0"))
    }

    func testXCUITestEmitterAvoidsSwiftKeywordsAndGeneratedScopeNames() throws {
        let test = makeTest(operations: [.init(
            id: "step-0",
            tool: "tap_element",
            arguments: ["id": "app"]
        )])

        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains(#"let appElement = app.descendants(matching: .any)["app"]"#))
        XCTAssertTrue(result.source.contains("appElement.tap()"))
    }

    func testXCUITestEmitterKeepsLocalNamesUniqueAgainstADigitSuffixedSelector() throws {
        // "field2" is claimed by the first selector, so the second reference to "field" must skip
        // past it rather than emitting a second `let field2`.
        let test = makeTest(operations: [
            .init(id: "step-0", tool: "tap_element", arguments: ["id": "field2"]),
            .init(id: "step-1", tool: "tap_element", arguments: ["id": "field"]),
            .init(id: "step-2", tool: "tap_element", arguments: ["id": "field"])
        ])

        let result = try XCUITestEmitter().generate(test)

        let declarations = result.source.split(separator: "\n").filter { $0.contains("        let ") }
        XCTAssertEqual(declarations.count, Set(declarations).count, "Generated duplicate local names.")
        XCTAssertTrue(result.source.contains(#"let field3 = app.descendants(matching: .any)["field"]"#))
    }

    // MARK: - EspressoEmitter

    func testEspressoEmitterGeneratesTapByID() throws {
        let test = makeTest(
            platform: .android,
            operations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "sign-in"])]
        )
        let result = try EspressoEmitter().generate(test)

        XCTAssertEqual(result.fileName, "SignInFlowTest.kt")
        XCTAssertTrue(result.source.contains("class SignInFlowTest"))
        XCTAssertTrue(result.source.contains("fun signInFlow()"))
        let matcher = #"anyOf(hasResourceEntryName("sign-in"), withContentDescription("sign-in"))"#
        XCTAssertTrue(result.source.contains("waitUntilDisplayed(\(matcher), 5000L)"))
        XCTAssertTrue(result.source.contains("onView(\(matcher)).perform(click())"))
        XCTAssertTrue(result.source.contains("private fun hasResourceEntryName"))
        XCTAssertTrue(result.source.contains("ActivityScenario.launch<Activity>(launchIntent).use"))
    }

    func testEspressoEmitterOmitsResourceNameHelperWhenNoIDSelectorsUsed() throws {
        let test = makeTest(
            platform: .android,
            operations: [.init(id: "op-1", tool: "tap_element", arguments: ["label": "Sign In"])]
        )
        let result = try EspressoEmitter().generate(test)

        let matcher = #"anyOf(withText("Sign In"), withContentDescription("Sign In"))"#
        XCTAssertTrue(result.source.contains("onView(\(matcher)).perform(click())"))
        XCTAssertFalse(result.source.contains("private fun hasResourceEntryName"))
    }

    func testEspressoEmitterGeneratesSetTextReplaceText() throws {
        let test = makeTest(
            platform: .android,
            operations: [.init(id: "op-1", tool: "set_text", arguments: ["id": "email", "value": "user@example.com"])]
        )
        let result = try EspressoEmitter().generate(test)

        let matcher = #"anyOf(hasResourceEntryName("email"), withContentDescription("email"))"#
        XCTAssertTrue(result.source.contains("waitUntilDisplayed(\(matcher), 5000L)"))
        XCTAssertTrue(result.source.contains("onView(\(matcher)).perform(replaceText(\"user@example.com\"))"))
    }

    func testEspressoEmitterThrowsForUnknownTool() {
        let test = makeTest(
            platform: .android,
            operations: [.init(id: "op-1", tool: "not_a_real_tool", arguments: [:])]
        )
        XCTAssertThrowsError(try EspressoEmitter().generate(test)) { error in
            XCTAssertEqual(error as? TestCodeGeneratorError, .unsupportedTool("not_a_real_tool"))
        }
    }

    func testEspressoEmitterGeneratesValidPressBackCall() throws {
        let test = makeTest(platform: .android, operations: [.init(id: "op-1", tool: "press_back", arguments: [:])])
        let result = try EspressoEmitter().generate(test)

        XCTAssertTrue(result.source.contains("import androidx.test.espresso.Espresso.pressBack"))
        XCTAssertTrue(result.source.contains("pressBack()"))
        XCTAssertFalse(result.source.contains("onView(isDisplayed()).perform(pressBack())"))
    }

    func testEspressoEmitterPreservesWaitTimeoutAndNotVisibleSemantics() throws {
        let test = makeTest(platform: .android, operations: [
            .init(id: "op-1", tool: "wait_for_element", arguments: ["label": "Ready", "timeout_ms": "1750"]),
            .init(id: "op-2", tool: "assert_not_visible", arguments: ["contains_text": "Loading"])
        ])
        let result = try EspressoEmitter().generate(test)

        XCTAssertTrue(result.source.contains("waitUntilDisplayed("))
        XCTAssertTrue(result.source.contains("1750L"))
        XCTAssertTrue(result.source.contains("waitUntilNotDisplayed("))
        XCTAssertFalse(result.source.contains("doesNotExist"))
    }

    func testEmittersRejectInvalidTimeouts() {
        let operation = StudioToolOperation(
            id: "op-1",
            tool: "wait_for_element",
            arguments: ["id": "ready", "timeout_ms": "not-a-number"]
        )

        XCTAssertThrowsError(try XCUITestEmitter().generate(makeTest(operations: [operation]))) { error in
            XCTAssertEqual(
                error as? TestCodeGeneratorError,
                .invalidArgument(tool: "wait_for_element", argument: "timeout_ms", value: "not-a-number")
            )
        }
        XCTAssertThrowsError(try EspressoEmitter().generate(makeTest(platform: .android, operations: [operation])))
    }

    func testEmittersRejectInvalidDirectionsInsteadOfSilentlySwipingUp() {
        let operation = StudioToolOperation(id: "op-1", tool: "scroll", arguments: ["direction": "diagonal"])
        let expected = TestCodeGeneratorError.invalidArgument(
            tool: "scroll", argument: "direction", value: "diagonal"
        )

        XCTAssertThrowsError(try XCUITestEmitter().generate(makeTest(operations: [operation]))) {
            XCTAssertEqual($0 as? TestCodeGeneratorError, expected)
        }
        XCTAssertThrowsError(try EspressoEmitter().generate(makeTest(platform: .android, operations: [operation]))) {
            XCTAssertEqual($0 as? TestCodeGeneratorError, expected)
        }
        XCTAssertThrowsError(try ComposeEspressoEmitter().generate(makeTest(
            platform: .android,
            operations: [operation]
        ))) {
            XCTAssertEqual($0 as? TestCodeGeneratorError, expected)
        }
    }

    // MARK: - ComposeEspressoEmitter

    func testComposeEmitterQueriesSemanticsAndUsesV2EmptyRule() throws {
        let test = makeTest(platform: .android, operations: [
            .init(id: "op-1", tool: "tap_element", arguments: ["id": "submit"]),
            .init(id: "op-2", tool: "assert_not_visible", arguments: ["label": "Loading"]),
            .init(id: "op-3", tool: "scroll", arguments: ["direction": "down"])
        ])

        let source = try ComposeEspressoEmitter().generate(test).source
        XCTAssertTrue(source.contains("junit4.v2.createEmptyComposeRule"))
        // Instrumented tests driving ActivityScenario need the Android runner; without it the
        // generated test compiles and then fails at run time, which codegen alone cannot catch.
        XCTAssertTrue(source.contains("@RunWith(AndroidJUnit4::class)"))
        XCTAssertTrue(source.contains(#"onNode(hasTestTag("submit")).assertIsDisplayed().performClick()"#))
        XCTAssertTrue(source.contains(
            #"composeTestRule.onAllNodes(hasContentDescription("Loading")).fetchSemanticsNodes().isEmpty() }"#
        ))
        XCTAssertFalse(source.contains("assertIsNotDisplayed()"))
        // scroll is the last step here — no follow-up target, so the distance-based fallback.
        XCTAssertTrue(source.contains("scrollByViewport(vertical = true, forward = true)"))
        XCTAssertTrue(source.contains("ActivityScenario.launch<Activity>(launchIntent).use"))
    }

    func testComposeEmitterScrollsViaSemanticsNotACoordinateSwipe() throws {
        // A swipe on onRoot() is not routed into Compose's nested-scroll system, and a LazyColumn's
        // scroll node can report zero bounds (making a coordinate swipe a no-op), so an unscoped
        // scroll is driven through semantics on the axis scroll container.

        // scroll followed by a targeted step -> scroll exactly until that target is on screen.
        let scrollThenAssert = makeTest(platform: .android, operations: [
            .init(id: "op-1", tool: "scroll", arguments: ["direction": "down"]),
            .init(id: "op-2", tool: "assert_enabled", arguments: ["contains_text": "New Videos"])
        ])
        let toNodeSource = try ComposeEspressoEmitter().generate(scrollThenAssert).source
        XCTAssertTrue(toNodeSource.contains(
            #"scrollContainer(vertical = true).performScrollToNode(hasText("New Videos", substring = true))"#
        ))
        XCTAssertTrue(toNodeSource.contains("private fun scrollContainer(vertical: Boolean): SemanticsNodeInteraction"))
        XCTAssertTrue(toNodeSource.contains("SemanticsProperties.VerticalScrollAxisRange"))
        XCTAssertFalse(toNodeSource.contains("onRoot().performTouchInput"))

        // scroll as the last step -> distance-based ScrollBy fallback, forward from the direction.
        let trailingScroll = makeTest(platform: .android, operations: [
            .init(id: "op-1", tool: "scroll", arguments: ["direction": "down"])
        ])
        let fallbackSource = try ComposeEspressoEmitter().generate(trailingScroll).source
        XCTAssertTrue(fallbackSource.contains("scrollByViewport(vertical = true, forward = true)"))
        XCTAssertTrue(fallbackSource.contains("performSemanticsAction(SemanticsActions.ScrollBy)"))

        // Axis + direction: scroll-up is a vertical backward scroll.
        let scrollUp = makeTest(platform: .android, operations: [
            .init(id: "op-1", tool: "scroll", arguments: ["direction": "up"])
        ])
        XCTAssertTrue(
            try ComposeEspressoEmitter().generate(scrollUp).source
                .contains("scrollByViewport(vertical = true, forward = false)")
        )

        // The helper is only emitted when an unscoped scroll needs it.
        let tapOnly = makeTest(platform: .android, operations: [
            .init(id: "op-1", tool: "tap_element", arguments: ["id": "go"])
        ])
        XCTAssertFalse(try ComposeEspressoEmitter().generate(tapOnly).source.contains("scrollContainer"))

        // An element-scoped swipe still targets that element with a real gesture.
        let swipeCard = makeTest(platform: .android, operations: [
            .init(id: "op-1", tool: "swipe_in_direction", arguments: ["direction": "left", "element_id": "card"])
        ])
        let cardSource = try ComposeEspressoEmitter().generate(swipeCard).source
        XCTAssertTrue(cardSource.contains(
            #"composeTestRule.onNode(hasTestTag("card")).assertIsDisplayed().performTouchInput { swipeLeft() }"#
        ))
    }

    func testComposeEmitterGuardsAssertionsWithPerStepTimeout() throws {
        let test = makeTest(platform: .android, operations: [
            .init(
                id: "op-1",
                tool: "assert_enabled",
                arguments: ["contains_text": "Most Loved", "timeout_ms": "10000"]
            ),
            .init(id: "op-2", tool: "assert_visible", arguments: ["label": "New Videos"])
        ])

        let source = try ComposeEspressoEmitter().generate(test).source

        // The recorded step polled up to timeout_ms; the generated code must wait the same way
        // instead of doing a single-shot check that races app load.
        XCTAssertTrue(source.contains(
            #"composeTestRule.waitUntil(timeoutMillis = 10000L) { composeTestRule"#
                + #".onAllNodes(hasText("Most Loved", substring = true))"#
                + #".fetchSemanticsNodes().isNotEmpty() }"#
        ))
        XCTAssertTrue(source
            .contains(#"composeTestRule.onNode(hasText("Most Loved", substring = true)).assertIsEnabled()"#))
        // No timeout_ms on the second step falls back to the shared default.
        XCTAssertTrue(source.contains(
            #"composeTestRule.waitUntil(timeoutMillis = 5000L) { composeTestRule"#
                + #".onAllNodes(hasContentDescription("New Videos"))"#
                + #".fetchSemanticsNodes().isNotEmpty() }"#
        ))
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
            platform: .android,
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
            platform: .android,
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
