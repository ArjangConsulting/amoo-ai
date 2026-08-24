import StudioProtocol

public enum TestCodeGeneratorError: Error, CustomStringConvertible, Equatable {
    case missingCompiledPlan
    case unsupportedTool(String)
    case missingArgument(tool: String, argument: String)

    public var description: String {
        switch self {
        case .missingCompiledPlan:
            "The test has no compiled tool operations to generate code from. Compile or attach a plan first."
        case let .unsupportedTool(tool):
            "No code generator mapping exists for tool '\(tool)'."
        case let .missingArgument(tool, argument):
            "Tool '\(tool)' is missing required argument '\(argument)'."
        }
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
