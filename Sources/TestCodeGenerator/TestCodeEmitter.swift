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
        while let start = call.range(of: "{{"), let end = call.range(
            of: "}}",
            range: start.upperBound ..< call.endIndex
        ) {
            let placeholder = String(call[start.upperBound ..< end.lowerBound])
            guard let value = operation.arguments[placeholder] else {
                throw TestCodeGeneratorError.invalidTestHelperTemplate(helper: helperName, placeholder: placeholder)
            }
            call.replaceSubrange(start.lowerBound ..< end.upperBound, with: literal(value))
        }
        return call
    }

    static func imports(for context: StudioTestContext?) -> [String] {
        // Parenthesise both operands: `+` binds tighter than `??`, so writing this as
        // `context?.imports ?? [] + helperImports` silently drops every helper import.
        let declared = (context?.imports ?? []) + (context?.helpers.flatMap(\.imports) ?? [])
        return Array(Set(declared)).sorted()
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

    /// Derives a readable lower-camel-case local name from the semantic information a recording
    /// already carries, **never** from opaque identifier tokens.
    ///
    /// Priority, highest first:
    /// 1. the accessible label / visible text;
    /// 2. a role inferred from the element type or from a role-shaped accessibility-ID segment
    ///    (`tab`, `button`, `row`, `field`, …), plus a semantic container segment when a label
    ///    anchored the name (`app.task_list.row.<uuid>` + "Cigarettes" → `cigarettesHabitRow`);
    /// 3. the last meaningful (non-opaque, non-role) identifier segment;
    /// 4. `element`.
    ///
    /// UUIDs, hashes, numeric record IDs and other opaque trailing segments are dropped entirely —
    /// they only ever appear in a name when nothing else exists (and even then a short deterministic
    /// suffix from `LocalNameAllocator` resolves collisions, never the raw ID).
    ///
    /// Examples: `app.tab.tasks` + "Habits" → `habitsTab`;
    /// `app.task_list.create_button` + "Create Habit" → `createHabitButton`;
    /// `sample.home.feed.sectionTitle.most_loved` → `mostLovedSectionTitle`.
    static func elementVariableBase(
        id: String? = nil,
        label: String? = nil,
        containsText: String? = nil,
        elementType: String? = nil
    ) -> String {
        let segments = (id ?? "")
            .split(separator: ".", omittingEmptySubsequences: true)
            .map(String.init)
        let appRoot = segments.count >= 3 ? segments.first : nil
        let roleSegmentIndex = segments.lastIndex(where: { isElementRole($0) })

        let (primary, primaryFromLabel) = primaryTokens(
            label: label, containsText: containsText, segments: segments, appRoot: appRoot
        )
        let container = primaryFromLabel
            ? containerTokens(
                segments: segments,
                appRoot: appRoot,
                roleSegmentIndex: roleSegmentIndex,
                primary: primary
            )
            : []
        let roleSource = roleSegmentIndex.map { roleWord(from: segments[$0]) }
            ?? elementType.flatMap(roleWord(forElementType:))
        let role = roleTokens(from: roleSource, following: primary)

        var combined = dropAdjacentDuplicates(primary + container + role)
        if combined.isEmpty {
            combined = ["element"]
        }
        return camelCase(combined.prefix(4).joined(separator: " "), fallback: "element")
    }

    /// The label wins; failing that, the last identifier segment that is neither opaque nor a bare
    /// role; failing that, any contains-text filter. Combined SwiftUI/Compose accessibility labels
    /// arrive comma-joined ("🚬 Cigarettes, Track how many…, Unit") — only the first clause names
    /// the element, the rest is prose that would bloat the variable name.
    private static func primaryTokens(
        label: String?,
        containsText: String?,
        segments: [String],
        appRoot: String?
    ) -> (tokens: [String], fromLabel: Bool) {
        let labelClause = label?.split(separator: ",").first.map(String.init) ?? label
        let fromLabel = words(from: labelClause)
        if !fromLabel.isEmpty {
            return (fromLabel, true)
        }
        if let index = segments.lastIndex(where: { !isOpaqueToken($0) && !isElementRole($0) }),
           segments[index] != appRoot {
            return (words(from: segments[index]), false)
        }
        return (words(from: containsText), false)
    }

    /// A semantic container segment (`habit_catalog` → `habit`), trusted only when a label anchored
    /// the name so a namespaced ID with no label keeps its `<segment><role>` shape.
    private static func containerTokens(
        segments: [String],
        appRoot: String?,
        roleSegmentIndex: Int?,
        primary: [String]
    ) -> [String] {
        // A standalone identifier such as `trash` is the selector, not an ancestor/container.
        // Only infer a container when the identifier path itself carries a role segment
        // (`app.task_list.row.<uuid>`). Element type still supplies the role independently.
        guard roleSegmentIndex != nil else { return [] }
        let segment = segments.indices.reversed().first { offset in
            offset != roleSegmentIndex && segments[offset] != appRoot
                && !isOpaqueToken(segments[offset]) && !isElementRole(segments[offset])
        }.map { segments[$0] }
        guard let segment else { return [] }
        let stripped = words(from: segment).filter { !containerNoiseWords.contains($0.lowercased()) }
        let primaryLower = Set(primary.map { $0.lowercased() })
        guard !stripped.isEmpty, !Set(stripped.map { $0.lowercased() }).isSubset(of: primaryLower) else {
            return []
        }
        return stripped
    }

    /// The role suffix, dropped when `primary` already ends with it (`habitsTab`, not `habitsTabTab`).
    private static func roleTokens(from role: String?, following primary: [String]) -> [String] {
        guard let role else { return [] }
        let tokens = words(from: role)
        let tail = primary.map { $0.lowercased() }.suffix(tokens.count)
        return tail.elementsEqual(tokens.map { $0.lowercased() }) ? [] : tokens
    }

    /// Identifier segments the naming must never treat as semantic: UUIDs, hex hashes, numeric
    /// record IDs, and long mixed opaque blobs.
    static func isOpaqueToken(_ token: String) -> Bool {
        var value = token
        while let first = value.first, "{(".contains(first) {
            value.removeFirst()
        }
        while let last = value.last, "})".contains(last) {
            value.removeLast()
        }
        if value.isEmpty {
            return true
        }
        if isUUID(value) {
            return true
        }
        if value.allSatisfy(\.isNumber) {
            return true
        }
        let hexNoDashes = value.replacingOccurrences(of: "-", with: "")
        if hexNoDashes.count >= 16, hexNoDashes.allSatisfy(\.isHexDigit) {
            return true
        }
        // A long, separator-free run of mixed letters and digits (base64-ish blobs, nanoids). Guard
        // it with the longest same-case letter run: a real identifier like
        // `recommendationsCarouselV2Section` has a long lowercase word in it; a random blob does not.
        let hasLetter = value.contains { $0.isLetter }
        let hasDigit = value.contains { $0.isNumber }
        let hasSeparator = value.contains { $0 == "_" || $0 == "-" }
        if value.count >= 20, hasLetter, hasDigit, !hasSeparator, longestSameCaseLetterRun(value) < 5 {
            return true
        }
        return false
    }

    /// Longest run of consecutive letters of the same case (non-letters reset the run).
    private static func longestSameCaseLetterRun(_ value: String) -> Int {
        var longest = 0
        var current = 0
        var lastWasUppercase: Bool?
        for character in value {
            guard character.isLetter else {
                current = 0
                lastWasUppercase = nil
                continue
            }
            if lastWasUppercase == character.isUppercase {
                current += 1
            } else {
                current = 1
            }
            lastWasUppercase = character.isUppercase
            longest = max(longest, current)
        }
        return longest
    }

    private static func isUUID(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5 else { return false }
        let lengths = [8, 4, 4, 4, 12]
        return zip(groups, lengths).allSatisfy { group, length in
            group.count == length && group.allSatisfy(\.isHexDigit)
        }
    }

    private static func words(from raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        // Drop apostrophes so "Don't" reads as one word ("dont"), not "Don" + "t".
        return raw
            .filter { $0 != "'" && $0 != "\u{2019}" }
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func dropAdjacentDuplicates(_ words: [String]) -> [String] {
        var result: [String] = []
        for word in words where result.last?.lowercased() != word.lowercased() {
            result.append(word)
        }
        return result
    }

    /// Container-shaped words dropped from a semantic container segment so
    /// `habit_catalog` contributes `habit`, not `habitCatalog`.
    private static let containerNoiseWords: Set<String> = [
        "catalog", "catalogue", "list", "grid", "collection", "container", "screen",
        "view", "section", "stack", "group", "scroll", "page", "table", "carousel"
    ]

    private static func roleWord(from segment: String) -> String {
        let normalized = segment.filter { $0.isLetter || $0.isNumber }.lowercased()
        if let known = knownRoles.first(where: { normalized == $0 || normalized.hasSuffix($0) }) {
            // Preserve the segment's own casing when it is exactly the role (e.g. `sectionTitle`).
            return normalized == known ? segment : known
        }
        return segment
    }

    private static func roleWord(forElementType type: String) -> String? {
        elementTypeRoles[type.lowercased().filter(\.isLetter)]
    }

    /// XCUI/Compose element type → the role word it contributes to a generated name. Keyed by the
    /// type lowercased with separators stripped, so `text_field` and `textField` both resolve.
    private static let elementTypeRoles: [String: String] = [
        "button": "button", "link": "button", "cell": "cell",
        "switch": "toggle", "toggle": "toggle",
        "textfield": "field", "searchfield": "field", "securetextfield": "field",
        "tab": "tab", "tabbar": "tab",
        "image": "image", "statictext": "label",
        "slider": "slider", "stepper": "stepper"
    ]

    private static let knownRoles = [
        "button", "cell", "field", "textfield", "image", "label", "link", "row",
        "sectiontitle", "section", "switch", "tab", "text", "title", "toggle", "view",
        "menu", "picker", "slider", "stepper", "checkbox", "chip", "card", "item"
    ]

    private static func isElementRole(_ value: String) -> Bool {
        let normalized = value.filter { $0.isLetter || $0.isNumber }.lowercased()
        if knownRoles.contains(normalized) {
            return true
        }
        // `create_button`, `habits_tab`: a role as the trailing token of an underscore segment.
        if let tail = value.split(separator: "_").last.map({ String($0).lowercased() }),
           tail != normalized, knownRoles.contains(tail) {
            return true
        }
        return false
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
///
/// Tracks the names actually handed out rather than a per-base counter: a selector ending in a
/// digit (`…field2`) would otherwise claim `field2` and collide with the second reference to
/// `field`, emitting two `let field2` bindings in one function.
struct LocalNameAllocator {
    private var used: Set<String> = []

    mutating func next(_ base: String) -> String {
        if used.insert(base).inserted {
            return base
        }
        var suffix = 2
        while true {
            let candidate = "\(base)\(suffix)"
            if used.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
    }
}
