import Foundation
@testable import StudioProtocol
import Testing

/// A small catalog with every shape the grammar distinguishes.
let grammarTestCatalog = StudioToolCatalog(tools: [
    .init(
        name: "tap_element",
        title: "Tap Element",
        description: "Tap a control",
        category: "action",
        readOnly: false,
        destructive: false,
        replSupported: true,
        planTool: "tap_element",
        arguments: [
            .init(name: "contains_text", type: "string", description: "Partial label", required: false),
            .init(name: "id", type: "string", description: "Accessibility id", required: false),
            .init(name: "label", type: "string", description: "Accessibility label", required: false)
        ]
    ),
    .init(
        name: "swipe_in_direction",
        title: nil,
        description: "Swipe",
        category: "action",
        readOnly: false,
        destructive: false,
        replSupported: true,
        planTool: "swipe_in_direction",
        arguments: [
            .init(
                name: "direction",
                type: "string",
                description: "Way",
                required: true,
                values: ["up", "down", "left", "right"]
            ),
            .init(name: "distance", type: "string", description: "Points", required: false)
        ]
    ),
    .init(
        name: "press_key",
        title: nil,
        description: "Press a key",
        category: "device",
        readOnly: false,
        destructive: false,
        replSupported: true,
        planTool: nil,
        arguments: [
            .init(
                name: "key",
                type: "string",
                description: "Key",
                required: true,
                values: ["return", "tab"],
                valuesAreExhaustive: false
            ),
            .init(name: "modifiers", type: "string", description: "Modifiers", required: false)
        ]
    ),
    .init(
        name: "find_elements",
        title: nil,
        description: "Find",
        category: "query",
        readOnly: true,
        destructive: false,
        replSupported: true,
        planTool: nil,
        arguments: [.init(name: "include_noise", type: "boolean", description: "Noise", required: false)]
    ),
    .init(
        name: "device_uninstall_app",
        title: nil,
        description: "Uninstall",
        category: "device",
        readOnly: false,
        destructive: true,
        replSupported: true,
        planTool: nil,
        arguments: [.init(name: "app_id", type: "string", description: "App", required: true)]
    ),
    .init(
        name: "start_session",
        title: nil,
        description: "Start",
        category: "session",
        readOnly: false,
        destructive: false,
        replSupported: false,
        planTool: nil,
        arguments: []
    )
])

@Suite("Console grammar")
struct StudioReplGrammarTests {
    let grammar = StudioReplGrammar(catalog: grammarTestCatalog)

    // MARK: Lexer

    @Test("tokens carry UTF-16 positions, so text after an emoji lines up with Studio's editor")
    func utf16Positions() {
        let tokens = StudioReplLexer.tokens(in: "tap_element label=\"👋 Hi\" id=x")

        #expect(tokens.map(\.value) == ["tap_element", "👋 Hi", "x"])
        #expect(tokens[1].start == 12)
        #expect(tokens[1].valueStart == 18)
        #expect(tokens[1].end == 25)
        #expect(tokens[2].start == 26)
        #expect(tokens[2].name == "id")
    }

    @Test("quotes work anywhere in a word, the other quote is literal, and only the first = names")
    func quoting() {
        let tokens = StudioReplLexer.tokens(in: "a label='say \"hi\"' x=a=b")

        #expect(tokens[1].name == "label")
        #expect(tokens[1].value == "say \"hi\"")
        #expect(tokens[2].name == "x")
        #expect(tokens[2].value == "a=b")
    }

    @Test("an unclosed quote swallows the rest of the line and is flagged")
    func unterminated() {
        let tokens = StudioReplLexer.tokens(in: "tap_element label=\"Sign in")

        #expect(tokens.count == 2)
        #expect(tokens[1].isTerminated == false)
        #expect(tokens[1].value == "Sign in")
    }

    // MARK: Parsing and diagnostics

    @Test("named and positional arguments parse into the tool call")
    func parsesToolCalls() {
        let named = grammar.parse("swipe_in_direction direction=up distance=200")
        let positional = grammar.parse("swipe_in_direction left")

        #expect(named.command == .tool(name: "swipe_in_direction", arguments: ["direction": "up", "distance": "200"]))
        #expect(named.diagnostics.isEmpty)
        #expect(positional.command == .tool(name: "swipe_in_direction", arguments: ["direction": "left"]))
    }

    @Test("built-in commands match case-insensitively and fill slots")
    func builtins() {
        #expect(grammar.parse("Devices List").command == .builtin("Devices List"))
        #expect(grammar.parse("devices inspect sim-1").command == .builtin("devices inspect sim-1"))
        #expect(grammar.parse("devices bogus").diagnostics.first?.message.contains("devices list") == true)
    }

    @Test("misspellings suggest the closest name")
    func suggestions() throws {
        let unknownTool = try #require(grammar.diagnostics(for: "tap_elemnt id=x").first)
        let unknownArgument = try #require(grammar.diagnostics(for: "tap_element lable=x").first)

        #expect(unknownTool.message.contains("Did you mean 'tap_element'"))
        #expect(unknownArgument.message.contains("Did you mean 'label'"))
        #expect(unknownArgument.start == 12)
        #expect(unknownArgument.end == 17)
    }

    @Test("exhaustive values are enforced case-insensitively; open value sets are not")
    func enumeratedValues() throws {
        let bad = try #require(grammar.diagnostics(for: "swipe_in_direction direction=sideways").first)

        #expect(bad.message == "direction must be one of: up, down, left, right.")
        #expect(bad.start == 29)
        #expect(grammar.diagnostics(for: "swipe_in_direction direction=UP").isEmpty)
        #expect(grammar.diagnostics(for: "press_key key=a").isEmpty)
    }

    @Test("missing, empty, duplicate, and unexpected arguments are each reported once")
    func argumentProblems() {
        #expect(grammar.diagnostics(for: "swipe_in_direction")
            .map(\.message) == ["Missing required argument: direction."])
        #expect(grammar.diagnostics(for: "tap_element id=").map(\.message) == ["Give a value for id."])
        let duplicate = grammar.diagnostics(for: "tap_element id=a id=b")
        #expect(duplicate.map(\.severity) == [.warning])
        #expect(grammar.parse("tap_element id=a id=b").command == .tool(name: "tap_element", arguments: ["id": "b"]))
        #expect(grammar.diagnostics(for: "tap_element stray").first?.message.contains("name=value") == true)
        #expect(grammar.diagnostics(for: "swipe_in_direction direction=\"up").map(\.message) == [
            "Close the quote that starts this value."
        ])
    }

    @Test("destructive and Studio-managed tools are refused in the console")
    func refusedTools() {
        #expect(grammar.diagnostics(for: "device_uninstall_app app_id=x").first?.message.contains("approval") == true)
        #expect(grammar.diagnostics(for: "start_session").first?.message.contains("managed by Studio") == true)
    }

    @Test("ordinary words such as 'delete' inside a value are not treated as destructive")
    func harmlessWords() {
        #expect(grammar.diagnostics(for: "tap_element label=\"delete account\"").isEmpty)
    }

    // MARK: Completion

    @Test("the first word offers commands and console tools, but not refused ones")
    func commandCompletion() {
        let result = grammar.complete(line: "ta", cursor: 2)
        let labels = result.items.map(\.label)

        #expect(result.replaceStart == 0)
        #expect(result.replaceEnd == 2)
        #expect(labels.contains("tap_element"))
        #expect(labels.contains("devices inspect <device>"))
        #expect(!labels.contains("device_uninstall_app"))
        #expect(!labels.contains("start_session"))
        #expect(result.items.first { $0.label == "devices inspect <device>" }?.insertText == "devices inspect ")
    }

    @Test("argument names skip ones already given and list required arguments first")
    func argumentNameCompletion() {
        let result = grammar.complete(line: "swipe_in_direction distance=10 ", cursor: 31)

        #expect(result.items.map(\.label) == ["direction"])
        #expect(result.items.first?.insertText == "direction=")
        #expect(result.replaceStart == 31)
        let fresh = grammar.complete(line: "swipe_in_direction ", cursor: 19).items.sorted { $0.sortText < $1.sortText }
        #expect(fresh.map(\.label) == ["direction", "distance"])
    }

    @Test("values offer enum members, booleans, and on-screen elements with quoting")
    func valueCompletion() {
        let direction = grammar.complete(line: "swipe_in_direction direction=u", cursor: 30)
        #expect(direction.replaceStart == 29)
        #expect(direction.items.map(\.label) == ["up", "down", "left", "right"])

        #expect(grammar.complete(line: "find_elements include_noise=", cursor: 28).items.map(\.label) == [
            "true",
            "false"
        ])

        let elements = [
            StudioElementSuggestion(id: "login", label: "Sign in", type: "button"),
            StudioElementSuggestion(id: "login", label: "Duplicate", type: "button"),
            StudioElementSuggestion(id: nil, label: "Say \"hi\"", type: "text")
        ]
        let labels = grammar.complete(line: "tap_element label=", cursor: 18, elements: elements)
        #expect(labels.items.map(\.insertText) == ["\"Sign in\"", "Duplicate", "'Say \"hi\"'"])
        let ids = grammar.complete(line: "tap_element id=", cursor: 15, elements: elements)
        #expect(ids.items.map(\.label) == ["login"])
        #expect(ids.items.first?.detail == "button · Sign in")
    }

    @Test("only selector values need the device")
    func needsElements() {
        #expect(grammar.needsElements(line: "tap_element id=", cursor: 15))
        #expect(!grammar.needsElements(line: "swipe_in_direction direction=", cursor: 29))
        #expect(!grammar.needsElements(line: "tap_element ", cursor: 12))
    }

    @Test("a device slot offers known devices")
    func deviceSlot() {
        let devices = [StudioDevice(
            id: "sim-1",
            name: "iPhone",
            platform: .ios,
            osVersion: "26",
            status: .running,
            physical: false
        )]
        let result = grammar.complete(line: "devices inspect ", cursor: 16, devices: devices)

        #expect(result.items.map(\.label) == ["sim-1"])
        #expect(result.items.first?.kind == .device)
    }

    @Test("completing in the middle of a line replaces only the word under the caret")
    func midLine() {
        let line = "tap_element id=abc label=x"
        let result = grammar.complete(line: line, cursor: 17)

        #expect(result.replaceStart == 15)
        #expect(result.replaceEnd == 18)
    }
}
