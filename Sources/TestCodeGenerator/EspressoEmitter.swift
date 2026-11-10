import StudioProtocol

// Emits a Kotlin Espresso instrumented test — no amoo companion app involved at run time.
//
// Companion-normalized element `id`s are runtime resource names or content descriptions as strings;
// idiomatic Espresso (`withId(R.id.foo)`) needs a compile-time `R` reference this generator can't
// resolve. Generated code falls back to a small `hasResourceEntryName` matcher instead of `R.id`,
// with a comment pointing at the substitution — swap it for `withId(R.id...)` where convenient.
// swiftlint:disable:next type_body_length
public struct EspressoEmitter: StudioCodeEmitting {
    /// The context `imports` entry that opts a generated test into the shared device helpers.
    static let sharedHelpersImport = "io.github.maniramezan.testcommons.device.*"

    private let useTestCommons: Bool

    /// Creates an emitter. Shared helpers require the KotlinTestCommons `device` artifact in the
    /// receiving `androidTest` source set.
    /// - Parameter useTestCommons: Whether to import and delegate to the shared helper library
    ///   instead of pasting the wait and matcher helpers into every generated test.
    public init(useTestCommons: Bool = false) {
        self.useTestCommons = useTestCommons
    }

    // SwiftLint measures the generated Kotlin template as Swift function body lines.
    // swiftlint:disable:next function_body_length
    public func generate(_ test: StudioAuthoredTest) throws -> StudioTestExportResult {
        guard let operations = test.compiledPlan?.toolOperations, operations.isEmpty == false else {
            throw TestCodeGeneratorError.missingCompiledPlan
        }
        let pascalName = TestIdentifierNaming.pascalCase(test.name)
        let className = "\(pascalName)Test"
        let methodName = pascalName.prefix(1).lowercased() + pascalName.dropFirst()
        let shared = useTestCommons
            || TestHelperRendering.imports(for: test.testContext).contains(Self.sharedHelpersImport)
        let body = try operations
            .map { try Self.statement(for: $0, context: test.testContext, useTestCommons: shared) }
            .joined(separator: "\n")
        let launchedBody = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }
            .joined(separator: "\n")
        let needsIndexMatcher = body.contains("withIndex(")
        let scrollImport = body
            .contains("scrollTo()") ? "\nimport androidx.test.espresso.action.ViewActions.scrollTo" : ""
        let nativeStateImports = operations.contains { [
            StudioTool.assertSelected,
            .assertChecked,
            .assertStateDescription
        ]
        .map(\.rawValue).contains($0.tool)
        }
            ? "\nimport androidx.test.espresso.matcher.ViewMatchers.isSelected"
            + "\nimport androidx.test.espresso.matcher.ViewMatchers.isChecked\nimport org.hamcrest.Matchers.not" : ""
        let stateDescriptionHelper = operations.contains { $0.tool == StudioTool.assertStateDescription.rawValue }
            ? Self.stateDescriptionMatcher : ""
        let ancestorImport = body.contains("isDescendantOfA(")
            ? "\nimport androidx.test.espresso.matcher.ViewMatchers.isDescendantOfA" : ""
        let allOfImport = body.contains("allOf(") ? "\nimport org.hamcrest.Matchers.allOf" : ""
        let needsResourceNameMatcher = operations.contains { operation in
            let identityKeys = ["id", "element_id", "parent_id", "to_id", "to_parent_id"]
            return identityKeys.contains { operation.arguments[$0] != nil } && [
                "tap_element", "drag", "pinch",
                "set_text",
                "wait_for_element",
                "assert_visible",
                "assert_not_visible",
                "assert_text",
                "assert_value",
                "assert_enabled", "assert_selected", "assert_checked", "assert_state_description"
            ].contains(operation.tool)
        }
        let needsGestureHelpers = Self.needsGestureHelpers(operations)
        let matcherHelpers = [
            shared ? nil : (needsResourceNameMatcher ? Self.resourceNameMatcherHelper : nil),
            shared ? nil : (needsIndexMatcher ? Self.indexMatcherHelper : nil),
            needsGestureHelpers ? Self.gestureHelpers : nil
        ].compactMap(\.self).map { $0 + "\n" }.joined(separator: "\n")
        let waitHelpers = shared ? "" : Self.waitHelpers
        let stateDescriptionBlock = stateDescriptionHelper.isEmpty ? "" : "\n" + stateDescriptionHelper
        let helperBlock = "\n\(matcherHelpers)\n\(waitHelpers)\(stateDescriptionBlock)\n"
        let gestureImports = needsGestureHelpers ? Self.gestureImports : ""
        let contextImports = TestHelperRendering.imports(for: test.testContext)
            .map { "import \($0)" }
            .joined(separator: "\n")
        let baseClass = test.testContext?.baseClass.map { " : \($0)" } ?? ""
        let importFragments = Self.ImportFragments(
            scroll: scrollImport,
            ancestor: ancestorImport,
            nativeState: nativeStateImports,
            allOf: allOfImport,
            gesture: gestureImports,
            context: contextImports
        )
        let importBlock = shared
            ? Self.sharedImports(
                body: body,
                nativeStateImports: nativeStateImports,
                gestureImports: gestureImports,
                contextImports: contextImports
            )
            : Self.standaloneImports(importFragments)
        let launchBlock = shared ? Self.sharedLaunch : Self.standaloneLaunch

        let source = """
        \(importBlock)

        /**
         * Generated by amoo from the Studio test "\(test.name)". Edit freely — this file has no
         * dependency on amoo or the companion apps once generated.
         */
        @RunWith(AndroidJUnit4::class)
        class \(className)\(baseClass) {\(helperBlock)
            @Test
            fun \(methodName)() {
        \(launchBlock)
        \(launchedBody)
                }
            }
        }
        """
        return StudioTestExportResult(fileName: "\(className).kt", source: source)
    }

    static let indent = "        "

    private static let resourceNameMatcherHelper: String = {
        let raw = """
        // Fallback for companion-reported resource names: generated code has no compile-time R.id
        // reference, so this matches on the runtime resource entry name. Recorded IDs also check
        // content descriptions because the companion uses those as IDs when available.
        private fun hasResourceEntryName(name: String): Matcher<View> {
            return object : TypeSafeMatcher<View>() {
                override fun describeTo(description: Description) {
                    description.appendText("with resource entry name: ").appendValue(name)
                }

                override fun matchesSafely(view: View): Boolean {
                    if (view.id == View.NO_ID) return false
                    return try {
                        view.resources.getResourceEntryName(view.id) == name
                    } catch (error: Exception) {
                        false
                    }
                }
            }
        }
        """
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    \($0)" }
            .joined(separator: "\n")
    }()

    /// Position-based matcher for a recorded `index` / `first`. Stateless — it recomputes the match
    /// list from the view's own hierarchy — because `waitUntil` re-evaluates one matcher many times,
    /// which a counting matcher would drift on.
    private static let indexMatcherHelper: String = {
        let raw = """
        private fun withIndex(matcher: Matcher<View>, index: Int): Matcher<View> {
            return object : TypeSafeMatcher<View>() {
                override fun describeTo(description: Description) {
                    description.appendText("the match at index $index of ").appendDescriptionOf(matcher)
                }

                override fun matchesSafely(view: View): Boolean {
                    if (!matcher.matches(view)) return false
                    val matches = TreeIterables.breadthFirstViewTraversal(view.rootView)
                        .filter { matcher.matches(it) }
                    return matches.getOrNull(index) === view
                }
            }
        }
        """
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    \($0)" }
            .joined(separator: "\n")
    }()

    private static let waitHelpers: String = {
        let raw = """
        private fun waitUntilDisplayed(matcher: Matcher<View>, timeoutMillis: Long): ViewAction =
            waitUntil(matcher, timeoutMillis, shouldBeDisplayed = true)

        private fun waitUntilNotDisplayed(matcher: Matcher<View>, timeoutMillis: Long): ViewAction =
            waitUntil(matcher, timeoutMillis, shouldBeDisplayed = false)

        private fun waitUntil(
            matcher: Matcher<View>,
            timeoutMillis: Long,
            shouldBeDisplayed: Boolean
        ): ViewAction {
            return object : ViewAction {
                override fun getConstraints(): Matcher<View> = isRoot()

                override fun getDescription(): String = if (shouldBeDisplayed) {
                    "wait up to ${timeoutMillis}ms for a displayed view matching $matcher"
                } else {
                    "wait up to ${timeoutMillis}ms for no displayed view matching $matcher"
                }

                override fun perform(uiController: UiController, root: View) {
                    val deadline = SystemClock.uptimeMillis() + timeoutMillis
                    do {
                        uiController.loopMainThreadUntilIdle()
                        val displayedMatchExists = TreeIterables.breadthFirstViewTraversal(root).any { view ->
                            matcher.matches(view) && isDisplayed().matches(view)
                        }
                        if (displayedMatchExists == shouldBeDisplayed) return
                        uiController.loopMainThreadForAtLeast(50)
                    } while (SystemClock.uptimeMillis() < deadline)

                    throw PerformException.Builder()
                        .withActionDescription(description)
                        .withViewDescription(HumanReadables.describe(root))
                        .withCause(TimeoutException(description))
                        .build()
                }
            }
        }
        """
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    \($0)" }
            .joined(separator: "\n")
    }()

    // A direct switch keeps the supported Studio-tool-to-Espresso mapping auditable in one place.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func statement(
        for operation: StudioToolOperation,
        context: StudioTestContext?,
        useTestCommons: Bool = false
    ) throws -> String {
        if let helper = try TestHelperRendering.call(for: operation, context: context, literal: literal) {
            return "\(indent)\(helper)"
        }
        guard let tool = StudioTool(rawValue: operation.tool) else {
            throw TestCodeGeneratorError.unsupportedTool(operation.tool)
        }
        // No `default`: adding a StudioTool case must fail to compile here until it is handled.
        switch tool {
        case .tapElement:
            let target = try matcher(operation)
            return try """
            \(indent)\(displayedWait(target, for: operation, shared: useTestCommons))
            \(indent)onView(\(target)).perform(click())
            """

        case .setText:
            guard let value = operation.arguments["value"] else {
                throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "value")
            }
            let target = try matcher(operation)
            return try """
            \(indent)\(displayedWait(target, for: operation, shared: useTestCommons))
            \(indent)onView(\(target)).perform(replaceText(\(literal(value))))
            """

        case .typeText:
            guard let text = operation.arguments["text"] else {
                throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "text")
            }
            return try """
            \(indent)\(displayedWait("hasFocus()", for: operation, shared: useTestCommons))
            \(indent)onView(hasFocus()).perform(replaceText(\(literal(text))))
            """

        case .swipeInDirection:
            let action = try "\(gesture(for: operation))()"
            let hasElement = operation.arguments["element_id"] != nil || operation.arguments["element_label"] != nil
            let target: String = if hasElement {
                try matcher(operation, idKey: "element_id", labelKey: "element_label")
            } else {
                "isDisplayed()"
            }
            guard hasElement else { return "\(indent)onView(isRoot()).perform(\(action))" }
            return try """
            \(indent)\(displayedWait(target, for: operation, shared: useTestCommons))
            \(indent)onView(\(target)).perform(\(action))
            """

        case .scroll:
            // GestureDirection inverts scroll for us — see its documentation for why.
            return try "\(indent)onView(isRoot()).perform(\(gesture(for: operation))())"

        case .drag:
            return try dragStatement(for: operation, shared: useTestCommons)

        case .pinch:
            return try pinchStatement(for: operation, shared: useTestCommons)

        case .waitForElement:
            let target = try matcher(operation)
            let timeout = try timeoutMilliseconds(for: operation)
            return "\(indent)\(displayedWait(target, timeout: timeout, shared: useTestCommons))"

        case .assertVisible:
            let target = try matcher(operation)
            return try """
            \(indent)\(displayedWait(target, for: operation, shared: useTestCommons))
            \(indent)onView(\(target)).check(matches(isDisplayed()))
            """

        case .assertNotVisible:
            let target = try matcher(operation)
            let timeout = try timeoutMilliseconds(for: operation)
            return "\(indent)\(notDisplayedWait(target, timeout: timeout, shared: useTestCommons))"

        case .assertText:
            guard let expected = operation.arguments["value"] ?? operation.arguments["expected"] else {
                throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "value")
            }
            let target = try matcher(operation)
            return try """
            \(indent)\(displayedWait(target, for: operation, shared: useTestCommons))
            \(indent)onView(\(target)).check(matches(withText(\(literal(expected)))))
            """

        case .assertValue:
            let exact = operation.arguments["value"] ?? operation.arguments["expected"]
            guard let expected = exact ?? operation.arguments["contains"] else {
                throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "value")
            }
            let textMatcher = exact == nil ? "containsString(\(literal(expected)))" : literal(expected)
            let target = try matcher(operation)
            // On Android Views, the accessibility value represented by assert_value is exposed as
            // text. Compose has its own semantics-specific implementation below.
            return try """
            \(indent)\(displayedWait(target, for: operation, shared: useTestCommons))
            \(indent)onView(\(target)).check(matches(withText(\(textMatcher))))
            """

        case .scrollToElement:
            let target = try matcher(operation)
            // `scrollTo()` scrolls a ScrollView/NestedScrollView; a RecyclerView needs
            // `RecyclerViewActions.scrollTo` with the same matcher, which this file cannot assume.
            return try """
            \(indent)onView(\(target)).perform(scrollTo())
            \(indent)\(displayedWait(target, for: operation, shared: useTestCommons))
            """

        case .assertSelected, .assertChecked:
            let expected = try SelectedAssertion.expectation(operation)
            let property = tool == .assertChecked ? "isChecked()" : "isSelected()"
            let state = expected ? property : "not(\(property))"
            let target = try matcher(operation)
            let timeout = try timeoutMilliseconds(for: operation)
            return try useTestCommons
                ? """
                \(indent)waitUntilDisplayed(
                \(indent)    allOf(\(target), \(state)), \(timeout)L
                \(indent))
                \(indent)onView(\(target)).check(matches(\(state)))
                """
                : """
                \(indent)onView(isRoot()).perform(waitUntilDisplayed(
                \(indent)    allOf(\(target), \(state)), \(timeout)L
                \(indent)))
                \(indent)onView(\(target)).check(matches(\(state)))
                """

        case .assertStateDescription:
            let exact = operation.arguments["value"] ?? operation.arguments["expected"]
            guard let expected = exact ?? operation.arguments["contains"] else {
                throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "expected")
            }
            let target = try matcher(operation)
            let state = "hasNativeStateDescription(\(literal(expected)), \(exact == nil))"
            let timeout = try timeoutMilliseconds(for: operation)
            return try useTestCommons
                ? """
                \(indent)waitUntilDisplayed(
                \(indent)    allOf(\(target), \(state)), \(timeout)L
                \(indent))
                \(indent)onView(\(target)).check(matches(\(state)))
                """
                : """
                \(indent)onView(isRoot()).perform(waitUntilDisplayed(
                \(indent)    allOf(\(target), \(state)), \(timeout)L
                \(indent)))
                \(indent)onView(\(target)).check(matches(\(state)))
                """

        case .assertEnabled:
            let target = try matcher(operation)
            return try """
            \(indent)\(displayedWait(target, for: operation, shared: useTestCommons))
            \(indent)onView(\(target)).check(matches(isEnabled()))
            """

        case .takeScreenshot:
            return "\(indent)// take_screenshot: capture via androidx.test.runner.screenshot.Screenshot "
                + "in an instrumented test if needed"

        case .relaunchApplication:
            guard let call = context?.relaunchHelper else {
                throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "relaunchHelper")
            }
            return "        \(call)"

        case .pressBack:
            return "\(indent)pressBack()"
        }
    }

    /// Espresso's `ViewActions` gesture name for this operation's direction.
    private static func gesture(for operation: StudioToolOperation) throws -> String {
        guard let raw = operation.arguments["direction"] else {
            throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "direction")
        }
        let direction = try GestureDirection.gestureDirection(for: operation.tool, rawDirection: raw)
        switch direction {
        case .up: return "swipeUp"
        case .down: return "swipeDown"
        case .left: return "swipeLeft"
        case .right: return "swipeRight"
        }
    }

    /// Every selector field is a constraint, so the target must satisfy all of them, inside the
    /// `parent_id` subtree when one is given. A `withIndex` pick applies to what survives.
    static func matcher(
        _ operation: StudioToolOperation,
        idKey: String = "id",
        labelKey: String = "label",
        containsTextKey: String = "contains_text"
    ) throws -> String {
        var constraints: [String] = []
        if let id = operation.arguments[idKey] {
            constraints.append(identityMatcher(id))
        }
        if let label = operation.arguments[labelKey] {
            constraints.append("anyOf(withText(\(literal(label))), withContentDescription(\(literal(label))))")
        }
        if let contains = operation.arguments[containsTextKey] {
            constraints.append(
                "anyOf(withText(containsString(\(literal(contains)))), "
                    + "withContentDescription(containsString(\(literal(contains)))))"
            )
        }
        if let parent = operation.arguments["parent_id"], !parent.isEmpty, !constraints.isEmpty {
            constraints.append("isDescendantOfA(\(identityMatcher(parent)))")
        }
        guard constraints.isEmpty == false else {
            throw TestCodeGeneratorError.missingArgument(
                tool: operation.tool, argument: "id, label, or contains_text"
            )
        }
        let base = constraints.count == 1 ? constraints[0] : "allOf(\(constraints.joined(separator: ", ")))"
        // A recorded `index` / `first` picks one of several identical matches; without it Espresso
        // throws AmbiguousViewMatcherException on the duplicates.
        guard let pick = try XCUITestEmitter.elementPick(operation) else { return base }
        return "withIndex(\(base), \(pick.position))"
    }

    private static func identityMatcher(_ id: String) -> String {
        "anyOf(hasResourceEntryName(\(literal(id))), withContentDescription(\(literal(id))))"
    }

    static func timeoutMilliseconds(for operation: StudioToolOperation) throws -> Int64 {
        guard let rawValue = operation.arguments["timeout_ms"] else { return 5000 }
        guard let milliseconds = Int64(rawValue), milliseconds > 0 else {
            throw TestCodeGeneratorError.invalidArgument(tool: operation.tool, argument: "timeout_ms", value: rawValue)
        }
        return milliseconds
    }

    private static func literal(_ value: String) -> String {
        var escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        escaped = String(escaped.unicodeScalars.map { scalar -> String in
            guard scalar.value < 0x20 else { return String(scalar) }
            let hex = String(scalar.value, radix: 16)
            return "\\u\(String(repeating: "0", count: 4 - hex.count))\(hex)"
        }.joined())
        return "\"\(escaped)\""
    }
}
