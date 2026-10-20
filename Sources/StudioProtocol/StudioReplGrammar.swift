import Foundation

/// One whitespace-separated word of a console line. Positions are UTF-16 offsets, matching
/// Studio's editor, and `end` is exclusive.
struct StudioReplToken: Equatable, Sendable {
    /// The source text, quotes included.
    let raw: String
    /// The text with quotes removed; for `name=value`, only the value.
    let value: String
    let start: Int
    let end: Int
    /// False when an opening quote never closed.
    let isTerminated: Bool
    /// The argument name of a `name=value` token.
    let name: String?
    /// Where the value of a `name=value` token starts; `start` otherwise.
    let valueStart: Int
}

/// Splits a console line the way the console has always tokenized it: whitespace separates words
/// outside quotes, `"` and `'` quote anywhere in a word (`label="Sign in"`), the other quote
/// character is literal inside quotes, and there are no backslash escapes.
enum StudioReplLexer {
    private struct Builder {
        let start: Int
        var raw = ""
        var value = ""
        var quote: Character?
        var name: String?
        var valueStart: Int

        init(start: Int) {
            self.start = start
            valueStart = start
        }

        func token(end: Int) -> StudioReplToken {
            .init(
                raw: raw,
                value: value,
                start: start,
                end: end,
                isTerminated: quote == nil,
                name: name,
                valueStart: valueStart
            )
        }
    }

    static func tokens(in line: String) -> [StudioReplToken] {
        var tokens: [StudioReplToken] = []
        var builder: Builder?
        var offset = 0
        for character in line {
            let width = character.utf16.count
            defer { offset += width }
            if builder?.quote == nil, character.isWhitespace {
                if let finished = builder {
                    tokens.append(finished.token(end: offset))
                    builder = nil
                }
                continue
            }
            var current = builder ?? Builder(start: offset)
            current.raw.append(character)
            if character == "\"" || character == "'" {
                if current.quote == character {
                    current.quote = nil
                } else if current.quote == nil {
                    current.quote = character
                } else {
                    current.value.append(character)
                }
            } else if character == "=", current.quote == nil, current.name == nil, isArgumentName(current.value) {
                current.name = current.value
                current.value = ""
                current.valueStart = offset + width
            } else {
                current.value.append(character)
            }
            builder = current
        }
        if let finished = builder {
            tokens.append(finished.token(end: offset))
        }
        return tokens
    }

    private static func isArgumentName(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// The console's command language: built-in commands and `tool name=value …` calls over the tool
/// catalog. Pure, so completion, validation, and execution all agree on how a line parses.
public struct StudioReplGrammar: Sendable {
    public enum Command: Equatable, Sendable {
        case empty
        case builtin(String)
        case tool(name: String, arguments: [String: String])
    }

    let tools: [String: StudioToolSchema]
    let orderedTools: [StudioToolSchema]
    let builtins: [StudioReplBuiltin]

    public init(catalog: StudioToolCatalog) {
        orderedTools = catalog.tools
        tools = Dictionary(catalog.tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        builtins = catalog.builtins
    }

    /// Parses `line`. The command is meaningful only when no diagnostic is an error.
    public func parse(_ line: String) -> (command: Command, diagnostics: [StudioReplDiagnostic]) {
        let tokens = StudioReplLexer.tokens(in: line)
        guard let first = tokens.first else { return (.empty, []) }
        if let builtin = matchingBuiltin(tokens) {
            return (.builtin(builtin), [])
        }
        if let diagnostic = partialBuiltinDiagnostic(tokens) {
            return (.empty, [diagnostic])
        }
        guard let tool = tools[first.value] else {
            let suggestion = closest(to: first.value, in: orderedTools.map(\.name) + builtins.map(\.command))
            let hint = suggestion.map { " Did you mean '\($0)'?" } ?? " Choose a suggestion or run help."
            return (.empty, [error(first, "Unknown command '\(first.value)'.\(hint)")])
        }
        return parseTool(tool, tokens: tokens)
    }

    public func diagnostics(for line: String) -> [StudioReplDiagnostic] {
        parse(line).diagnostics
    }

    private func parseTool(
        _ tool: StudioToolSchema,
        tokens: [StudioReplToken]
    ) -> (command: Command, diagnostics: [StudioReplDiagnostic]) {
        let toolToken = tokens[0]
        var diagnostics: [StudioReplDiagnostic] = []
        if !tool.replSupported {
            diagnostics.append(error(toolToken, "\(tool.name) is managed by Studio and cannot run in the console."))
        } else if tool.destructive {
            diagnostics.append(error(
                toolToken,
                "\(tool.name) can destroy device or app state. Use Devices so Studio can ask for approval."
            ))
        }
        var arguments: [String: String] = [:]
        for token in tokens.dropFirst() {
            diagnostics += apply(token, to: &arguments, of: tool)
        }
        let missing = tool.arguments.filter { $0.required && arguments[$0.name] == nil }.map(\.name)
        if !missing.isEmpty {
            let noun = missing.count == 1 ? "argument" : "arguments"
            diagnostics.append(error(toolToken, "Missing required \(noun): \(missing.joined(separator: ", "))."))
        }
        return (.tool(name: tool.name, arguments: arguments), diagnostics)
    }

    /// Records one argument word into `arguments` and returns what is wrong with it.
    private func apply(
        _ token: StudioReplToken,
        to arguments: inout [String: String],
        of tool: StudioToolSchema
    ) -> [StudioReplDiagnostic] {
        let nextPositional = tool.arguments.first { $0.required && arguments[$0.name] == nil }
        guard token.isTerminated else {
            // Count the argument as given so the line is not also reported as missing it.
            if let name = token.name ?? nextPositional?.name {
                arguments[name] = token.value
            }
            return [error(token, "Close the quote that starts this value.")]
        }
        guard let name = token.name else {
            guard let nextPositional else {
                return [error(token, "Unexpected value '\(token.value)'. Write it as name=value.")]
            }
            arguments[nextPositional.name] = token.value
            return valueProblem(token.value, for: nextPositional).map { [error(token, $0)] } ?? []
        }
        guard let argument = tool.arguments.first(where: { $0.name == name }) else {
            let hint = closest(to: name, in: tool.arguments.map(\.name)).map { " Did you mean '\($0)'?" } ?? ""
            return [.init(
                start: token.start,
                end: token.valueStart - 1,
                severity: .error,
                message: "\(tool.name) has no argument '\(name)'.\(hint)"
            )]
        }
        var diagnostics: [StudioReplDiagnostic] = []
        if arguments[name] != nil {
            diagnostics.append(.init(
                start: token.start,
                end: token.end,
                severity: .warning,
                message: "\(name) is given more than once; the last value is used."
            ))
        }
        if token.value.isEmpty {
            diagnostics.append(error(token, "Give a value for \(name)."))
        } else if let problem = valueProblem(token.value, for: argument) {
            diagnostics.append(.init(start: token.valueStart, end: token.end, severity: .error, message: problem))
        }
        arguments[name] = token.value
        return diagnostics
    }

    private func valueProblem(_ value: String, for argument: StudioToolArgument) -> String? {
        guard argument.valuesAreExhaustive, let values = argument.values, !values.isEmpty,
              !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
        else { return nil }
        return "\(argument.name) must be one of: \(values.joined(separator: ", "))."
    }

    // MARK: Built-in commands

    func matchingBuiltin(_ tokens: [StudioReplToken]) -> String? {
        let words = tokens.map(\.value)
        let match = builtins.first { builtin in
            let pattern = builtin.words
            guard pattern.count == words.count else { return false }
            return zip(pattern, words).allSatisfy { expected, actual in
                Self.isSlot(expected) || expected.caseInsensitiveCompare(actual) == .orderedSame
            }
        }
        guard match != nil else { return nil }
        return words.joined(separator: " ")
    }

    /// A line that starts like a built-in (`devices`) but does not match one gets a targeted message.
    private func partialBuiltinDiagnostic(_ tokens: [StudioReplToken]) -> StudioReplDiagnostic? {
        let first = tokens[0].value.lowercased()
        let family = builtins.filter { $0.words.first?.lowercased() == first && $0.words.count > 1 }
        guard !family.isEmpty, tools[tokens[0].value] == nil else { return nil }
        let options = family.map(\.command).joined(separator: ", ")
        let last = tokens[tokens.count - 1]
        return .init(
            start: tokens[0].start,
            end: last.end,
            severity: .error,
            message: "Incomplete or unknown \(first) command. Try: \(options)."
        )
    }

    static func isSlot(_ word: String) -> Bool {
        word.hasPrefix("<") && word.hasSuffix(">")
    }

    // MARK: Helpers

    private func error(_ token: StudioReplToken, _ message: String) -> StudioReplDiagnostic {
        .init(start: token.start, end: token.end, severity: .error, message: message)
    }

    /// The candidate within two edits of `word`, for "did you mean" hints.
    func closest(to word: String, in candidates: [String]) -> String? {
        let lowered = word.lowercased()
        return candidates
            .map { ($0, Self.editDistance(lowered, $0.lowercased())) }
            .filter { $0.1 <= 2 && $0.1 < max(lowered.count, 1) }
            .min { $0.1 < $1.1 }?
            .0
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }
        var previous = Array(0 ... right.count)
        for (row, leftCharacter) in left.enumerated() {
            var current = [row + 1] + Array(repeating: 0, count: right.count)
            for (column, rightCharacter) in right.enumerated() {
                let substitution = previous[column] + (leftCharacter == rightCharacter ? 0 : 1)
                current[column + 1] = min(previous[column + 1] + 1, current[column] + 1, substitution)
            }
            previous = current
        }
        return previous[right.count]
    }
}
