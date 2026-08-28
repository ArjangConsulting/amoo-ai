import StudioProtocol

/// Binds compiled operations to declared context helpers when the match is unambiguous.
///
/// `compile_session_to_plan` never sets `StudioToolOperation.helper`, so `StudioTestContext.helpers`
/// only ever took effect for AI-authored plans that named a helper by hand. This pass closes that
/// gap for `generate test`: an operation with no helper is bound to a context helper whose call
/// template takes exactly the arguments the operation carries and whose name or template reads as
/// the operation's verb. Anything less certain than that is left unbound — a wrong binding silently
/// changes what the generated test does, which is worse than a missing convenience.
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
    /// helper name and the literal (non-placeholder) text of its call template, both lowercased.
    private static let toolKeywords: [StudioTool: [String]] = [
        .tapElement: ["tap", "press", "click", "select"],
        .setText: ["settext", "fill", "type", "enter", "input"],
        .typeText: ["type", "enter", "input"],
        .swipeInDirection: ["scroll", "swipe"],
        .scroll: ["scroll", "swipe"],
        .waitForElement: ["wait", "await"],
        .assertVisible: ["assert", "expect", "verify", "visible", "shown", "displayed"],
        .assertNotVisible: ["assert", "expect", "verify", "hidden", "absent", "gone"],
        .assertText: ["assert", "expect", "verify", "text", "equals"],
        .assertEnabled: ["assert", "expect", "verify", "enabled"],
        .takeScreenshot: ["screenshot", "snapshot"],
        .pressBack: ["back", "navigateup", "pop"]
    ]

    private static func keywords(for tool: String) -> [String] {
        StudioTool(rawValue: tool).flatMap { toolKeywords[$0] } ?? []
    }

    private static func match(
        operation: StudioToolOperation,
        helpers: [StudioTestContext.Helper]
    ) -> String? {
        let verbs = keywords(for: operation.tool)
        guard verbs.isEmpty == false else { return nil }

        let candidates = helpers.filter { helper in
            let placeholders = placeholders(in: helper.callTemplate)
            // A helper that takes the same arguments the operation already carries. Zero-placeholder
            // helpers are excluded: matching them on a verb alone is too little evidence to rewrite
            // the operation.
            guard placeholders.isEmpty == false,
                  placeholders.allSatisfy({ operation.arguments[$0] != nil })
            else { return false }
            let haystack = (helper.name + " " + templateLiteralText(helper.callTemplate)).lowercased()
            return verbs.contains { haystack.contains($0) }
        }
        return candidates.count == 1 ? candidates[0].name : nil
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
