import CLIReadline
import MCPServer

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
        cli_reset_completions()
        cli_set_root_completions(rootCandidates.joined(separator: "\n"))

        for command in commandCandidates.keys.sorted() {
            let arguments = argumentCandidates(for: command)
            guard !arguments.isEmpty else { continue }
            cli_set_command_completions(command, arguments.joined(separator: "\n"))
        }
    }
}
