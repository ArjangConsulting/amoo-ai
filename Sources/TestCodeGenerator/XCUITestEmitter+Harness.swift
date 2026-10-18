import StudioProtocol

extension XCUITestEmitter {
    static func assertionCall(
        _ operation: StudioToolOperation,
        context: StudioTestContext?,
        localNames: inout LocalNameAllocator,
        lookups: inout [String: String]
    ) throws -> String? {
        guard let template = context?.assertionBindings[operation.tool] else { return nil }
        // `expected` of a selection check is a state, not text; it has its own placeholder below.
        let isSelection = operation.tool == StudioTool.assertSelected.rawValue
        let value = operation.arguments["value"] ?? (isSelection ? nil : operation.arguments["expected"])
        let contains = operation.arguments["contains"]
        // A binding must preserve the recorded expectation, including substring semantics.
        if (value != nil && !template.contains("{{value}}"))
            || (contains != nil && !template.contains("{{contains}}")) {
            throw TestCodeGeneratorError.invalidArgument(
                tool: operation.tool, argument: "assertionBindings", value: "template drops the recorded expectation"
            )
        }
        // The selected state has no string form to match on, so it has its own placeholder, and the
        // template must carry it or selected and unselected would render the same call.
        var selected: Bool?
        if operation.tool == StudioTool.assertSelected.rawValue {
            guard template.contains("{{selected}}") else {
                throw TestCodeGeneratorError.invalidArgument(
                    tool: operation.tool,
                    argument: "assertionBindings",
                    value: "template drops the recorded expectation"
                )
            }
            selected = try SelectedAssertion.expectation(operation)
        }
        if template.contains("{{value}}"), value == nil {
            throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "value")
        }
        if template.contains("{{contains}}"), contains == nil {
            throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "contains")
        }
        let (_, variable, declaration) = try lookup(
            operation, context: context, localNames: &localNames, lookups: &lookups
        )
        let call = try template.replacingOccurrences(of: "{{element}}", with: variable)
            .replacingOccurrences(of: "{{timeout}}", with: timeoutExpression(operation, context: context))
            .replacingOccurrences(of: "{{value}}", with: literal(value ?? ""))
            .replacingOccurrences(of: "{{contains}}", with: literal(contains ?? ""))
            .replacingOccurrences(of: "{{selected}}", with: selected.map(String.init) ?? "")
        return "\(declaration)\n\(indent)\(call)"
    }

    /// One call to a generated wait helper. `named:` carries the local variable's name so a
    /// timeout failure says which element it was waiting on.
    static func waitCall(
        _ helper: String,
        _ variable: String,
        _ operation: StudioToolOperation,
        context: StudioTestContext? = nil
    ) throws -> String {
        let timeout = try timeoutExpression(operation, context: context)
        if let template = context?.waitBindings[helper] {
            return template.replacingOccurrences(of: "{{element}}", with: variable)
                .replacingOccurrences(of: "{{timeout}}", with: timeout)
        }
        return
            "\(helper)(\(variable), named: \(literal(variable)), timeout: \(timeout))"
    }

    static func timeoutExpression(_ operation: StudioToolOperation, context: StudioTestContext?) throws -> String {
        // Validate recorded timeouts even when the repository replaces their literal representation.
        if let raw = operation.arguments["timeout_ms"], Int64(raw).map({ $0 > 0 }) != true {
            throw TestCodeGeneratorError.invalidArgument(tool: operation.tool, argument: "timeout_ms", value: raw)
        }
        let key = operation.arguments["timeout_ms"] ?? "default"
        if let expression = context?.timeoutExpressions[key] {
            return expression
        }
        return String(Double(operation.arguments["timeout_ms"].flatMap(Int64.init) ?? 5000) / 1000)
    }

    static func applyingHarness(to source: String, context: StudioTestContext?) -> String {
        guard let context else { return source }
        var source = source
        if let timeout = context.timeoutExpressions["default"] {
            source = source.replacingOccurrences(
                of: "private let defaultTimeout: TimeInterval = 5",
                with: "private let defaultTimeout: TimeInterval = \(timeout)"
            )
        }
        if context.harnessOwnsApp {
            source = source.replacingOccurrences(
                of: "    private lazy var app = \(context.appFactory ?? "XCUIApplication()")\n", with: ""
            )
            if !source.contains("@MainActor\nfinal class") {
                source = source.replacingOccurrences(of: "final class ", with: "@MainActor\nfinal class ")
            }
        }
        if let expression = context.factoryOverride,
           let insertion = source.range(of: "    override func setUp") {
            source.insert(contentsOf: """
                override func makeApplication() -> XCUIApplication {
                    \(expression)
                }


            """, at: insertion.lowerBound)
        }
        for helper in context.waitBindings.keys {
            if let start = source.range(of: "    private func \(helper)("),
               let end = source.range(of: "\n    private func ", range: start.upperBound ..< source.endIndex) {
                source.removeSubrange(start.lowerBound ..< end.lowerBound)
            }
        }
        return source
    }
}
