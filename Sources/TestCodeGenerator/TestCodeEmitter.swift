import StudioProtocol

public enum TestCodeGeneratorError: Error, CustomStringConvertible, Equatable {
    case missingCompiledPlan
    case unsupportedTool(String)
    case missingArgument(tool: String, argument: String)
    case invalidArgument(tool: String, argument: String, value: String)
    case unknownTestHelper(String)
    case invalidTestHelperTemplate(helper: String, placeholder: String)

    public var description: String {
        switch self {
        case .missingCompiledPlan:
            "The test has no compiled tool operations to generate code from. Compile or attach a plan first."
        case let .unsupportedTool(tool):
            "No code generator mapping exists for tool '\(tool)'."
        case let .missingArgument(tool, argument):
            "Tool '\(tool)' is missing required argument '\(argument)'."
        case let .invalidArgument(tool, argument, value):
            "Tool '\(tool)' has invalid argument '\(argument)': '\(value)'."
        case let .unknownTestHelper(name):
            "Generated operation requests test helper '\(name)', but it is absent from testContext.helpers."
        case let .invalidTestHelperTemplate(helper, placeholder):
            "Test helper '\(helper)' references missing operation argument '\(placeholder)'."
        }
    }
}

enum TestHelperRendering {
    /// Renders only helpers explicitly chosen by the planner. This prevents a helper with a
    /// plausible name from silently changing a recorded test's behavior.
    static func call(
        for operation: StudioToolOperation,
        context: StudioTestContext?,
        literal: (String) -> String
    ) throws -> String? {
        guard let helperName = operation.helper else { return nil }
        guard let helper = context?.helper(named: helperName) else {
            throw TestCodeGeneratorError.unknownTestHelper(helperName)
        }

        var call = helper.callTemplate
        while let start = call.range(of: "{{"), let end = call.range(of: "}}", range: start.upperBound..<call.endIndex) {
            let placeholder = String(call[start.upperBound..<end.lowerBound])
            guard let value = operation.arguments[placeholder] else {
                throw TestCodeGeneratorError.invalidTestHelperTemplate(helper: helperName, placeholder: placeholder)
            }
            call.replaceSubrange(start.lowerBound..<end.upperBound, with: literal(value))
        }
        return call
    }

    static func imports(for context: StudioTestContext?) -> [String] {
        Array(Set(context?.imports ?? []
            + (context?.helpers.flatMap(\.imports) ?? []))).sorted()
    }
}

/// The direction of a `swipe_in_direction` or `scroll` operation.
///
/// Shared by all three emitters because the distinction between the two tools is easy to get
/// wrong and expensive when you do: `swipe_in_direction` names the raw finger direction, while
/// `scroll` names the direction the *content* moves. The companions implement `scroll(.down)` as
/// a swipe-up gesture (see `XCUITestBridge.scroll` / `UIAutomatorBridge.scroll`), so a scroll must
/// invert before it becomes a gesture. Encoding that once keeps the emitters from disagreeing.
enum GestureDirection: String {
    case up, down, left, right

    var inverted: Self {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }

    /// The direction to actually gesture in for `tool`, accounting for scroll's inversion.
    static func gestureDirection(for tool: String, rawDirection: String) throws -> Self {
        guard let parsed = Self(rawValue: rawDirection.lowercased()) else {
            throw TestCodeGeneratorError.invalidArgument(
                tool: tool,
                argument: "direction",
                value: rawDirection
            )
        }
        return tool == "scroll" ? parsed.inverted : parsed
    }
}

enum TestIdentifierNaming {
    /// PascalCases a free-form test name into a valid Swift/Kotlin identifier fragment.
    static func pascalCase(_ raw: String) -> String {
        let words = raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let camel = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        guard let first = camel.first else { return "GeneratedTest" }
        return first.isNumber ? "_\(camel)" : camel
    }

    /// Produces a lower-camel-case local identifier from user-facing text or an accessibility ID.
    /// The source selector remains the test's contract; this only makes generated code easier to
    /// review and maintain.
    static func camelCase(_ raw: String, fallback: String) -> String {
        let pascal = pascalCase(raw)
        guard let first = pascal.first else { return fallback }
        let identifier = first.lowercased() + pascal.dropFirst()
        guard identifier != "_" else { return fallback }
        return reservedLocalNames.contains(identifier) ? "\(identifier)Element" : identifier
    }

    /// Uses the meaningful end of namespaced accessibility IDs. For example,
    /// `sample.home.feed.sectionTitle.most_loved` becomes `mostLovedSectionTitle`.
    static func elementVariableBase(
        id: String? = nil,
        label: String? = nil,
        containsText: String? = nil
    ) -> String {
        if let id, !id.isEmpty {
            let components = id.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
            if let last = components.last {
                let descriptiveName: String
                if components.count > 1, let preceding = components.dropLast().last, isElementRole(preceding) {
                    descriptiveName = "\(last) \(preceding)"
                } else {
                    descriptiveName = last
                }
                return camelCase(descriptiveName, fallback: "element")
            }
        }
        if let label, !label.isEmpty {
            return camelCase(label, fallback: "element")
        }
        if let containsText, !containsText.isEmpty {
            return camelCase(containsText, fallback: "element")
        }
        return "element"
    }

    private static func isElementRole(_ value: String) -> Bool {
        let normalized = value.filter { $0.isLetter || $0.isNumber }.lowercased()
        return [
            "button", "cell", "field", "image", "label", "link", "row", "section", "sectiontitle",
            "switch", "tab", "text", "textfield", "title", "toggle", "view"
        ].contains(normalized)
    }

    /// Local variables live alongside `app`, and must never be Swift keywords or contextual names.
    private static let reservedLocalNames: Set<String> = [
        "actor", "app", "associatedtype", "break", "case", "catch", "class", "continue", "default",
        "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "for", "func", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is",
        "let", "nil", "open", "operator", "private", "protocol", "public", "repeat", "rethrows", "return",
        "self", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
        "typealias", "var", "where", "while"
    ]
}

/// Keeps repeated references legal without giving up the semantic name of the element.
struct LocalNameAllocator {
    private var counts: [String: Int] = [:]

    mutating func next(_ base: String) -> String {
        let count = (counts[base] ?? 0) + 1
        counts[base] = count
        return count == 1 ? base : "\(base)\(count)"
    }
}
