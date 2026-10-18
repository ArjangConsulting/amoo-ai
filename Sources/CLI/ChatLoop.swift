import AmooCore
import Foundation
import MCPServer
import OllamaClient
import SwiftyTerminal
import SwiftyTerminalLineEditor

/// The `amoo chat` interactive loop: user types natural language, Ollama calls MCP tools.
struct ChatLoop {
    private let executor: any ToolExecutor
    private let ollamaClient: OllamaClient
    private let tools: [OllamaTool]
    private let toolSchemas: [ToolBridge.ToolSchema]
    private let model: String
    private let maxToolCallsPerTurn: Int

    /// `internal` (rather than `private`) so tests can drive a single conversation
    /// turn or slash command without going through the real terminal readline loop.
    var messages: [ChatMessage] = []

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
                properties: def.properties.map {
                    ToolBridge.SchemaProperty(key: $0.key, type: $0.value.type, description: $0.value.description)
                },
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

    mutating func processConversationTurn() async {
        var toolCallCount = 0

        while true {
            do {
                await startThinking()
                let response = try await ollamaClient.chat(
                    model: model,
                    messages: messages,
                    tools: tools
                )

                await stopThinking()

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
                await stopThinking()
                printFormatted("Error: \(error)", style: .error)
                break
            }
        }
    }

    // MARK: - Slash Commands

    /// Returns true if the command was handled, false if it's /quit.
    mutating func handleSlashCommand(_ input: String) -> Bool {
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
        LineEditor().readLine(prompt: "\n" + "you".styled(.cyan) + " › ")
    }

    private func setupCompletions() {
        LineEditor().setCompletions(commands: ["/help", "/tools", "/history", "/clear", "/model", "/quit"])
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
        print(banner.styled(.cyan))
    }

    /// The "thinking…" spinner shown while waiting for the model.
    private var thinking: Spinner?

    private mutating func startThinking() async {
        let spinner = Spinner("thinking...", delay: .zero)
        await spinner.start()
        thinking = spinner
    }

    private mutating func stopThinking() async {
        await thinking?.stop()
        thinking = nil
    }

    private func printToolCall(_ call: ToolCall) {
        let args = call.arguments.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        print("  ⚡ ".styled(.yellow) + call.name.styled(.yellow) + "(\(args))".styled(.gray))
    }

    private func printToolResult(_ name: String, _ result: ToolResult) {
        let text = result.content
        let preview = text.count > 200 ? String(text.prefix(200)) + "..." : text
        let icon = result.isError ? "  ✗ ".styled(.red) : "  ✓ ".styled(.green)
        print(icon + preview.styled(.gray))
    }

    private func printAssistant(_ content: String) {
        print()
        print("  " + "assistant".styled(.green) + " › " + content)
    }

    private func printHelp() {
        let help = """
          /tools    - List available MCP tools with descriptions
          /history  - Show conversation messages
          /clear    - Reset conversation (keep system prompt)
          /model    - Show current model
          /quit     - Exit chat
        """
        print(help.styled(.gray))
    }

    private func printTools() {
        print("  Available tools (\(toolSchemas.count)):".styled(.cyan))
        for schema in toolSchemas.sorted(by: { $0.name < $1.name }) {
            print("    • " + schema.name.styled(.yellow) + " - " + schema.description.styled(.gray))
        }
    }

    private func printHistory() {
        print("  Conversation (\(messages.count) messages):".styled(.cyan))
        for (i, msg) in messages.enumerated() {
            let role = msg.role.rawValue.styled(msg.role == .user ? .cyan : msg.role == .assistant ? .green : .gray)
            let preview = msg.content.prefix(80)
            print("    \(i). [\(role)] \(preview)")
        }
    }

    enum Style {
        case info, warning, error, dim
    }

    private func printFormatted(_ text: String, style: Style) {
        switch style {
        case .info: print("  ℹ ".styled(.cyan) + text)
        case .warning: print("  ⚠ ".styled(.yellow) + text)
        case .error: print("  ✗ ".styled(.red) + text)
        case .dim: print("  " + text.styled(.gray))
        }
    }
}
