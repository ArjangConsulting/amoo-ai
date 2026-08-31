import StudioProtocol

/// Binds compiled operations to declared context helpers when the match is unambiguous.
///
/// `compile_session_to_plan` never sets `StudioToolOperation.helper`, so `StudioTestContext.helpers`
/// only ever took effect for AI-authored plans that named a helper by hand. This pass closes that
/// gap for `generate test`: an operation with no helper is bound to a context helper whose call
/// template consumes every argument that decides what the step does (taking nothing the operation
/// lacks) and whose name or template reads as the operation's verb. Anything less certain than that
/// is left unbound — a wrong binding silently changes what the generated test does, which is worse
/// than a missing convenience.
public enum HelperBinder {
    /// Returns `test` with its compiled operations bound to matching context helpers. A no-op when
    /// there is no context, no helpers, no compiled plan, or nothing matched cleanly.
    public static func bindingContextHelpers(_ test: StudioAuthoredTest) -> StudioAuthoredTest {
        guard let context = test.testContext, context.helpers.isEmpty == false,
              let plan = test.compiledPlan, let operations = plan.toolOperations
        else { return test }

        let bound = operations.map { operation -> StudioToolOperation in
            guard operation.helper == nil,
                  let name = match(operation: operation, helpers: context.helpers)
            else { return operation }
            return operation.bindingHelper(name)
        }
        guard bound != operations else { return test }

        let reboundPlan = StudioCompiledPlan(
            compiler: plan.compiler,
            compilerVersion: plan.compilerVersion,
            operations: plan.operations ?? [],
            toolOperations: bound,
            warnings: plan.warnings
        )
        return StudioAuthoredTest(
            formatVersion: test.formatVersion,
            name: test.name,
            description: test.description,
            platform: test.platform,
            steps: test.steps,
            requirements: test.requirements,
            testContext: test.testContext,
            compiledPlan: reboundPlan
        )
    }

    /// Verbs that identify a helper as an implementation of a given Studio tool. Matched against the
    /// word tokens of the helper name and the literal (non-placeholder) text of its call template.
    /// A multi-word verb matches a consecutive run of tokens.
    private static let toolKeywords: [StudioTool: [[String]]] = [
        .tapElement: [["tap"], ["press"], ["click"], ["select"], ["choose"]],
        .setText: [["set", "text"], ["set"], ["fill"], ["type"], ["enter"], ["input"]],
        .typeText: [["type"], ["enter"], ["input"]],
        .swipeInDirection: [["scroll"], ["swipe"]],
        .scroll: [["scroll"], ["swipe"]],
        .waitForElement: [["wait"], ["await"]],
        .assertVisible: [["assert"], ["expect"], ["verify"], ["visible"], ["shown"], ["displayed"]],
        .assertNotVisible: [["assert"], ["expect"], ["verify"], ["hidden"], ["absent"], ["gone"]],
        .assertText: [["assert"], ["expect"], ["verify"], ["text"], ["equals"]],
        .assertValue: [["assert"], ["expect"], ["verify"], ["value"], ["equals"]],
        .assertEnabled: [["assert"], ["expect"], ["verify"], ["enabled"]],
        .takeScreenshot: [["screenshot"], ["snapshot"]],
        .pressBack: [["back"], ["navigate", "up"], ["pop"]]
    ]

    /// Arguments that decide what a step actually does. A helper must consume every one the
    /// operation carries, or binding to it silently changes the test — a `set_text` bound to
    /// `fillField(id: {{id}})` would drop the text being typed and still compile. Everything
    /// else (`timeout_ms`, `session_id`, …) is incidental and may go unused.
    private static let semanticArgumentKeys: Set<String> = [
        "id", "element_id", "label", "element_label", "contains_text", "element_contains_text",
        "text", "value", "expected", "direction"
    ]

    private static func keywords(for tool: String) -> [[String]] {
        StudioTool(rawValue: tool).flatMap { toolKeywords[$0] } ?? []
    }

    private static func match(
        operation: StudioToolOperation,
        helpers: [StudioTestContext.Helper]
    ) -> String? {
        let verbs = keywords(for: operation.tool)
        guard verbs.isEmpty == false else { return nil }
        let semantic = Set(operation.arguments.keys.filter(semanticArgumentKeys.contains))

        let candidates = helpers.filter { helper in
            let placeholders = Set(placeholders(in: helper.callTemplate))
            // The helper must take arguments the operation has, and must take *all* of the ones
            // that matter. Zero-placeholder helpers are excluded: matching them on a verb alone is
            // too little evidence to rewrite the operation.
            guard placeholders.isEmpty == false,
                  placeholders.allSatisfy({ operation.arguments[$0] != nil }),
                  semantic.isSubset(of: placeholders)
            else { return false }
            let tokens = words(helper.name) + words(templateLiteralText(helper.callTemplate))
            return verbs.contains { contains(tokens, run: $0) }
        }
        return candidates.count == 1 ? candidates[0].name : nil
    }

    /// Lowercased word tokens, splitting on non-alphanumerics and camel humps. Whole-token matching
    /// is what keeps `tapCenter` from reading as a `set_text` helper via the substring `enter`.
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).flatMap { chunk -> [String] in
            var tokens: [String] = []
            var current = ""
            for character in chunk {
                if character.isUppercase, current.isEmpty == false {
                    tokens.append(current)
                    current = ""
                }
                current.append(character)
            }
            if current.isEmpty == false {
                tokens.append(current)
            }
            return tokens.map { $0.lowercased() }
        }
    }

    private static func contains(_ tokens: [String], run: [String]) -> Bool {
        guard run.isEmpty == false, tokens.count >= run.count else { return false }
        return tokens.indices.dropLast(run.count - 1).contains { start in
            Array(tokens[start ..< start + run.count]) == run
        }
    }

    private static func placeholders(in template: String) -> [String] {
        var result: [String] = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{"),
              let close = rest.range(of: "}}", range: open.upperBound ..< rest.endIndex) {
            result.append(String(rest[open.upperBound ..< close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return result
    }

    private static func templateLiteralText(_ template: String) -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{"),
              let close = rest.range(of: "}}", range: open.upperBound ..< rest.endIndex) {
            output += rest[rest.startIndex ..< open.lowerBound]
            rest = rest[close.upperBound...]
        }
        output += rest
        return output
    }
}
