import AmooCore
import CLIReadline
import Foundation
import MCPServer
import OllamaClient

/// Convenience extension to use method syntax for coloring.
private extension String {
    func colored(_ color: ANSIColor) -> String {
        AmooCore.colored(self, color)
    }
}

/// The `amoo chat` interactive loop: user types natural language, Ollama calls MCP tools.
struct ChatLoop {
    private let executor: any ToolExecutor
    private let ollamaClient: OllamaClient
    private let tools: [OllamaTool]
    private let toolSchemas: [ToolBridge.ToolSchema]
    private let model: String
    private let maxToolCallsPerTurn: Int

    private var messages: [ChatMessage] = []

    init(
        executor: any ToolExecutor,
        ollamaClient: OllamaClient,
        toolDefinitions: [ToolDefinition],
        model: String,
        systemPrompt: String,
        maxToolCallsPerTurn: Int = 10
    ) {
        self.executor = executor
        self.ollamaClient = ollamaClient
        self.model = model
        self.maxToolCallsPerTurn = maxToolCallsPerTurn

        // Convert MCP ToolDefinitions to ToolBridge schemas
        toolSchemas = toolDefinitions.map { def in
            ToolBridge.ToolSchema(
                name: def.name,
                description: def.description,
                properties: def.properties
                    .map { (key: $0.key, type: $0.value.type, description: $0.value.description) },
                required: def.required
            )
        }
        tools = ToolBridge.toOllamaTools(toolSchemas)

        messages = [ChatMessage(role: .system, content: systemPrompt)]
    }

    mutating func run() async {
        printBanner()
        setupCompletions()

        while true {
            guard let input = readInput() else { break }
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            // Handle slash commands
            if trimmed.hasPrefix("/") {
                if handleSlashCommand(trimmed) {
                    continue
                } else {
                    break
                } // /quit
            }

            // Add user message
            messages.append(ChatMessage(role: .user, content: trimmed))

            // Run the Ollama ↔ tool loop
            await processConversationTurn()
        }

        printFormatted("\n👋 Goodbye!", style: .dim)
    }

    // MARK: - Conversation Turn

    private mutating func processConversationTurn() async {
        var toolCallCount = 0

        while true {
            do {
                startThinking()
                let response = try await ollamaClient.chat(
                    model: model,
                    messages: messages,
                    tools: tools
                )

                stopThinking()

                if response.hasToolCalls {
                    // Execute each tool call
                    for call in response.toolCalls {
                        toolCallCount += 1
                        printToolCall(call)

                        let result = await executor.execute(
                            toolName: call.name,
                            arguments: call.arguments
                        )
                        printToolResult(call.name, result)

                        // Append assistant message with tool call indication
                        messages.append(ChatMessage(role: .assistant, content: ""))
                        // Append tool result
                        messages.append(ChatMessage(
                            role: .tool,
                            content: result.content,
                            toolCallID: call.name
                        ))
                    }

                    // Check depth limit
                    if toolCallCount >= maxToolCallsPerTurn {
                        printFormatted(
                            "⚠ Reached \(maxToolCallsPerTurn) tool calls. Asking model to summarize.",
                            style: .warning
                        )
                        messages.append(ChatMessage(
                            role: .user,
                            content: "Please summarize what you've done so far. Do not call more tools."
                        ))
                    }

                    // Continue loop to let model process tool results
                    continue
                } else {
                    // Model produced a text response — show it
                    messages.append(ChatMessage(role: .assistant, content: response.content))
                    printAssistant(response.content)
                    break
                }
            } catch {
                stopThinking()
                printFormatted("Error: \(error)", style: .error)
                break
            }
        }
    }

    // MARK: - Slash Commands

    /// Returns true if the command was handled, false if it's /quit.
    private mutating func handleSlashCommand(_ input: String) -> Bool {
        let parts = input.split(separator: " ", maxSplits: 1)
        let command = String(parts[0]).lowercased()

        switch command {
        case "/quit", "/exit", "/q":
            return false
        case "/help":
            printHelp()
        case "/tools":
            printTools()
        case "/history":
            printHistory()
        case "/clear":
            messages = [messages[0]] // keep system prompt
            printFormatted("Conversation cleared.", style: .info)
        case "/model":
            if parts.count > 1 {
                printFormatted("Model switching requires restarting: amoo chat --model \(parts[1])", style: .info)
            } else {
                printFormatted("Current model: \(model)", style: .info)
            }
        default:
            printFormatted("Unknown command: \(command). Type /help for available commands.", style: .warning)
        }
        return true
    }

    // MARK: - Input

    private func readInput() -> String? {
        let prompt = "\n" + "you".colored(.cyan) + " › "
        guard let line = cli_readline(prompt) else { return nil }
        defer { free(line) }
        let input = String(cString: line)
        cli_save_history(input)
        return input
    }

    private func setupCompletions() {
        let slashCommands = ["/help", "/tools", "/history", "/clear", "/model", "/quit"]
        cli_reset_completions()
        for cmd in slashCommands {
            cli_set_root_completions(cmd)
        }
    }

    // MARK: - Output Formatting

    private func printBanner() {
        let banner = """

        ┌─────────────────────────────────────────────┐
        │  amoo chat · AI-powered mobile testing REPL  │
        │  Model: \(model.padding(toLength: 36, withPad: " ", startingAt: 0)) │
        │  Type /help for commands, /quit to exit      │
        └─────────────────────────────────────────────┘

        """
        print(banner.colored(.cyan))
    }

    /// Animated spinner task handle — cancelled by `stopThinking()`.
    private var thinkingTask: Task<Void, Never>?

    private mutating func startThinking() {
        thinkingTask = Task { @MainActor in
            let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            var i = 0
            while !Task.isCancelled {
                let frame = frames[i % frames.count]
                print("\r\u{1B}[K  \(frame) thinking...".colored(.gray), terminator: "")
                fflush(stdout)
                i += 1
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private mutating func stopThinking() {
        thinkingTask?.cancel()
        thinkingTask = nil
        print("\r\u{1B}[K", terminator: "")
        fflush(stdout)
    }

    private func printToolCall(_ call: ToolCall) {
        let args = call.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        print("  ⚡ ".colored(.yellow) + call.name.colored(.yellow) + "(\(args))".colored(.gray))
    }

    private func printToolResult(_ name: String, _ result: ToolResult) {
        let text = result.content
        let preview = text.count > 200 ? String(text.prefix(200)) + "..." : text
        let icon = result.isError ? "  ✗ ".colored(.red) : "  ✓ ".colored(.green)
        print(icon + preview.colored(.gray))
    }

    private func printAssistant(_ content: String) {
        print()
        print("  " + "assistant".colored(.green) + " › " + content)
    }

    private func printHelp() {
        let help = """
          /tools    - List available MCP tools with descriptions
          /history  - Show conversation messages
          /clear    - Reset conversation (keep system prompt)
          /model    - Show current model
          /quit     - Exit chat
        """
        print(help.colored(.gray))
    }

    private func printTools() {
        print("  Available tools (\(toolSchemas.count)):".colored(.cyan))
        for schema in toolSchemas.sorted(by: { $0.name < $1.name }) {
            print("    • " + schema.name.colored(.yellow) + " - " + schema.description.colored(.gray))
        }
    }

    private func printHistory() {
        print("  Conversation (\(messages.count) messages):".colored(.cyan))
        for (i, msg) in messages.enumerated() {
            let role = msg.role.rawValue.colored(msg.role == .user ? .cyan : msg.role == .assistant ? .green : .gray)
            let preview = msg.content.prefix(80)
            print("    \(i). [\(role)] \(preview)")
        }
    }

    enum Style {
        case info, warning, error, dim
    }

    private func printFormatted(_ text: String, style: Style) {
        switch style {
        case .info: print("  ℹ ".colored(.cyan) + text)
        case .warning: print("  ⚠ ".colored(.yellow) + text)
        case .error: print("  ✗ ".colored(.red) + text)
        case .dim: print("  " + text.colored(.gray))
        }
    }
}
