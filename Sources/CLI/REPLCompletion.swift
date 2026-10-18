import MCPServer
import SwiftyTerminalLineEditor

struct REPLCompletionCatalog {
    private static let builtins = ["?", "exit", "help", "quit", "tools"]

    let rootCandidates: [String]
    private let commandCandidates: [String: [String]]

    init(toolDefinitions: [ToolDefinition]) {
        var root = Set(Self.builtins)
        var commandCandidates: [String: [String]] = [:]

        for definition in toolDefinitions {
            root.insert(definition.name)
            commandCandidates[definition.name] = definition.properties.keys.sorted().map { "\($0)=" }
        }

        rootCandidates = root.sorted()
        self.commandCandidates = commandCandidates
    }

    func argumentCandidates(for command: String) -> [String] {
        commandCandidates[command] ?? []
    }

    func install() {
        LineEditor().setCompletions(
            commands: rootCandidates,
            arguments: commandCandidates.filter { !$0.value.isEmpty }
        )
    }
}
