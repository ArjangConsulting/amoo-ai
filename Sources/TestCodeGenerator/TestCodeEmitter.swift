import StudioProtocol

public enum TestCodeGeneratorError: Error, CustomStringConvertible, Equatable {
    case missingCompiledPlan
    case unsupportedTool(String)
    case missingArgument(tool: String, argument: String)
    case invalidArgument(tool: String, argument: String, value: String)

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
        }
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
}
