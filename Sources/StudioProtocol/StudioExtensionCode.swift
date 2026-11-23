/// Test code that flow extensions (`amoo-ext-<prefix> emit`) supplied for one generated test.
///
/// `amoo generate test` asks each extension the plan uses for its setup, step and teardown code and
/// attaches the result here. Each extension step becomes an operation whose tool is
/// ``operationTool`` and whose `code` argument holds its lines, so an emitter places step code in
/// order without knowing which extension wrote it. amoo owns indentation and placement.
public struct StudioExtensionCode: Codable, Equatable, Sendable {
    /// The tool of an operation that carries extension-supplied lines in its `code` argument.
    public static let operationTool = "extension_code"
    /// The argument holding an extension operation's lines, newline-separated.
    public static let codeArgument = "code"
    /// The argument holding an extension step's arguments as written in the flow, as a JSON object,
    /// so `emit` receives numbers, booleans and nested objects rather than their text.
    public static let argumentsJSONArgument = "arguments_json"

    /// Modules (Swift) or fully qualified names (Kotlin) to import.
    public var imports: [String]
    /// Declarations added to the test class: properties, helper functions.
    public var members: [String]
    /// Lines run before the app launches, in extension order.
    public var setUp: [String]
    /// Lines run after the test, in reverse extension order.
    public var tearDown: [String]
    /// The test function has to throw.
    public var requiresThrows: Bool
    /// The test function has to be `async` (Swift) or able to suspend (Kotlin).
    public var requiresAsync: Bool

    public init(
        imports: [String] = [],
        members: [String] = [],
        setUp: [String] = [],
        tearDown: [String] = [],
        requiresThrows: Bool = false,
        requiresAsync: Bool = false
    ) {
        self.imports = imports
        self.members = members
        self.setUp = setUp
        self.tearDown = tearDown
        self.requiresThrows = requiresThrows
        self.requiresAsync = requiresAsync
    }

    /// The lines an extension operation carries, or `nil` for any other operation.
    public static func lines(of operation: StudioToolOperation) -> [String]? {
        guard operation.tool == operationTool else { return nil }
        let code = operation.arguments[codeArgument] ?? ""
        return code.isEmpty ? [] : code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Whether `tool` names a flow extension's step (`prefix.step`), which only an extension can emit.
    public static func isExtensionTool(_ tool: String) -> Bool {
        let parts = tool.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy(isName)
    }

    private static func isName(_ part: Substring) -> Bool {
        guard let first = part.first, first.isASCII, first.isLowercase else { return false }
        return part.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "_" }
    }
}
