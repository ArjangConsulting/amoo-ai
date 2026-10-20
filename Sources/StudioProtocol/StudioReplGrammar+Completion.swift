import Foundation

/// Console completion. Split from `StudioReplGrammar.swift` to keep both files within size limits.
public extension StudioReplGrammar {
    /// What the word under the caret is, which decides what completion offers.
    enum CompletionContext: Equatable, Sendable {
        /// The first word: a tool or a built-in command.
        case command(range: Range<Int>)
        /// A later word of a built-in command, such as `inspect` or a `<device>` slot.
        case builtinWord(slot: String?, candidates: [String], range: Range<Int>)
        /// An argument name after a tool.
        case argumentName(tool: String, range: Range<Int>)
        /// The value of `name=` after a tool.
        case argumentValue(tool: String, argument: String, range: Range<Int>)
        case none
    }

    /// Which element field a selector argument's values come from.
    internal enum ElementField: Sendable {
        case id
        case label

        func value(of element: StudioElementSuggestion) -> String? {
            switch self {
            case .id: element.id
            case .label: element.label
            }
        }
    }

    /// Arguments whose values name elements on screen, and which element field each offers.
    internal static let selectorArguments: [String: ElementField] = [
        "id": .id,
        "element_id": .id,
        "parent_id": .id,
        "label": .label,
        "element_label": .label,
        "contains_text": .label
    ]

    func completionContext(line: String, cursor: Int) -> CompletionContext {
        let tokens = StudioReplLexer.tokens(in: line)
        let index = tokens.firstIndex { $0.start <= cursor && cursor <= $0.end }
        let tokenIndex = index ?? tokens.count(where: { $0.end <= cursor })
        let token = index.map { tokens[$0] }
        let wordRange = token.map { $0.start ..< $0.end } ?? cursor ..< cursor
        if tokenIndex == 0 {
            return .command(range: wordRange)
        }
        let commandName = tokens[0].value
        if let tool = tools[commandName] {
            if let token, token.name != nil, cursor >= token.valueStart {
                return .argumentValue(
                    tool: tool.name,
                    argument: token.name ?? "",
                    range: token.valueStart ..< token.end
                )
            }
            return .argumentName(tool: tool.name, range: wordRange)
        }
        let typed = tokens.prefix(tokenIndex).map { $0.value.lowercased() }
        let family = builtins.map(\.words).filter { words in
            words.count > tokenIndex && zip(words, typed).allSatisfy { expected, actual in
                Self.isSlot(expected) || expected.lowercased() == actual
            }
        }
        guard !family.isEmpty else { return .none }
        let slot = family.map { $0[tokenIndex] }.first(where: Self.isSlot)
        let literals = family.map { $0[tokenIndex] }.filter { !Self.isSlot($0) }
        return .builtinWord(slot: slot, candidates: Array(Set(literals)).sorted(), range: wordRange)
    }

    /// Whether completing at `cursor` would offer elements from the device, so the service only
    /// queries the device when the answer is used.
    func needsElements(line: String, cursor: Int) -> Bool {
        if case let .argumentValue(_, argument, _) = completionContext(line: line, cursor: cursor) {
            return Self.selectorArguments[argument] != nil
        }
        return false
    }

    /// Completes the word under `cursor`. `elements` and `devices` fill selector values and
    /// `<device>` slots; pass empty lists when they are unknown.
    func complete(
        line: String,
        cursor: Int,
        elements: [StudioElementSuggestion] = [],
        devices: [StudioDevice] = []
    ) -> StudioReplCompletionResult {
        switch completionContext(line: line, cursor: cursor) {
        case let .command(range):
            return result(range, commandItems())
        case let .builtinWord(slot, candidates, range):
            var items = candidates.map { StudioCompletionItem(label: $0, insertText: $0, kind: .command) }
            if slot == "<device>" {
                items += devices.map { device in
                    StudioCompletionItem(
                        label: device.id,
                        insertText: device.id,
                        detail: "\(device.name) · \(device.platform.rawValue) \(device.osVersion)",
                        kind: .device
                    )
                }
            }
            return result(range, items)
        case let .argumentName(toolName, range):
            return result(range, argumentNameItems(toolName: toolName, line: line, cursor: cursor))
        case let .argumentValue(toolName, argumentName, range):
            let argument = tools[toolName]?.arguments.first { $0.name == argumentName }
            return result(range, valueItems(argument: argument, elements: elements))
        case .none:
            return .empty(at: cursor)
        }
    }

    private func result(_ range: Range<Int>, _ items: [StudioCompletionItem]) -> StudioReplCompletionResult {
        .init(replaceStart: range.lowerBound, replaceEnd: range.upperBound, items: items)
    }

    private func commandItems() -> [StudioCompletionItem] {
        let toolItems = orderedTools.filter { $0.replSupported && !$0.destructive }.map { tool in
            StudioCompletionItem(
                label: tool.name,
                insertText: tool.name,
                detail: tool.title ?? tool.category,
                documentation: tool.description,
                kind: .tool,
                sortText: "1\(tool.name)"
            )
        }
        let builtinItems = builtins.map { builtin in
            let fixed = builtin.words.prefix { !Self.isSlot($0) }.joined(separator: " ")
            let insert = fixed.count < builtin.command.count ? fixed + " " : fixed
            return StudioCompletionItem(
                label: builtin.command,
                insertText: insert,
                detail: "Studio command",
                documentation: builtin.description,
                kind: .command,
                sortText: "0\(builtin.command)"
            )
        }
        return builtinItems + toolItems
    }

    private func argumentNameItems(toolName: String, line: String, cursor: Int) -> [StudioCompletionItem] {
        guard let tool = tools[toolName] else { return [] }
        let used = Set(
            StudioReplLexer.tokens(in: line)
                .filter { !($0.start <= cursor && cursor <= $0.end) }
                .compactMap(\.name)
        )
        return tool.arguments.filter { !used.contains($0.name) }.map { argument in
            let requirement = argument.required ? "required" : "optional"
            return StudioCompletionItem(
                label: argument.name,
                insertText: "\(argument.name)=",
                detail: "\(argument.type) · \(requirement)",
                documentation: argument.description,
                kind: .argument,
                sortText: "\(argument.required ? 0 : 1)\(argument.name)"
            )
        }
    }

    private func valueItems(
        argument: StudioToolArgument?,
        elements: [StudioElementSuggestion]
    ) -> [StudioCompletionItem] {
        guard let argument else { return [] }
        var items: [StudioCompletionItem] = []
        var seen = Set<String>()
        for value in argument.values ?? [] where seen.insert(value).inserted {
            items.append(.init(label: value, insertText: Self.quoted(value), detail: argument.name, kind: .value))
        }
        if argument.type == "boolean" {
            for value in ["true", "false"] where seen.insert(value).inserted {
                items.append(.init(label: value, insertText: value, kind: .value))
            }
        }
        if let field = Self.selectorArguments[argument.name] {
            for (position, element) in elements.enumerated() {
                guard let value = field.value(of: element), !value.isEmpty,
                      seen.insert(value).inserted else { continue }
                let other = field == .id ? element.label : element.id
                let detail = [element.type, other].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
                items.append(.init(
                    label: value,
                    insertText: Self.quoted(value),
                    detail: detail.isEmpty ? nil : detail,
                    kind: .element,
                    sortText: String(format: "%05d", position)
                ))
            }
        }
        return items
    }

    /// Quotes a value that would otherwise split or change meaning, preferring double quotes.
    internal static func quoted(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { $0.isWhitespace || $0 == "\"" || $0 == "'" }
        guard needsQuotes else { return value }
        return value.contains("\"") ? "'\(value)'" : "\"\(value)\""
    }
}
