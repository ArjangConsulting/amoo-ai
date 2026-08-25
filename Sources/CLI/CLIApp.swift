import AmooCore
import AuditEngine
import Foundation
import MCPServer
import StudioProtocol
import TestCodeGenerator
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CLIResult: Sendable, Equatable {
    public var output: String
    public var exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public struct CLIApp {
    /// The version reported by `amoo --version`.
    ///
    /// For released binaries this is overwritten at build time by the release workflow, which
    /// stamps it from the git tag (see `.github/workflows/release.yml`). The literal below is the
    /// fallback for local/dev builds and should track the most recent release tag.
    public static let versionString = "0.1.0"

    private let mcpServer: MCPServer
    private let preflightChecker: any PreflightChecking
    private let auditRunner: any AuditRunning

    public init(
        mcpServer: MCPServer = .init(),
        preflightChecker: any PreflightChecking = DefaultPreflightChecker(),
        auditRunner: any AuditRunning = DefaultAuditRunner()
    ) {
        self.mcpServer = mcpServer
        self.preflightChecker = preflightChecker
        self.auditRunner = auditRunner
    }

    public func run(args: [String]) async -> CLIResult {
        if args.isEmpty {
            // Default interactive mode when no arguments are provided.
            await startREPLMode(args: args)
            return CLIResult(output: "", exitCode: 0)
        }

        if args == ["--version"] {
            return CLIResult(output: Self.versionString, exitCode: 0)
        }

        if isHelpToken(args.first) {
            return CLIResult(output: renderCLIHelp(), exitCode: 0)
        }

        if args.contains("--tools") {
            return CLIResult(output: mcpServer.toolNames().joined(separator: ","), exitCode: 0)
        }

        if let result = await dispatchSubcommand(args: args) {
            return result
        }

        // Default: interactive REPL mode
        await startREPLMode(args: args)
        return CLIResult(output: "", exitCode: 0)
    }

    private func dispatchSubcommand(args: [String]) async -> CLIResult? {
        let remaining = Array(args.dropFirst())
        switch args.first {
        case "preflight": return await handlePreflightCommand(remaining: remaining)
        case "device": return await handleDeviceCommand(remaining: remaining)
        case "companion": return await handleCompanionCommand(remaining: remaining)
        case "flow": return await handleFlowCommand(remaining: remaining)
        case "audit": return await handleAuditCommand(remaining: remaining)
        case "chat": return await handleChatCommand(remaining: remaining)
        case "mcp": return await handleMCPCommand(remaining: remaining)
        case "studio": return await handleStudioCommand(remaining: remaining)
        case "generate": return handleGenerateCommand(remaining: remaining)
        default: return nil
        }
    }

    private func handleGenerateCommand(remaining: [String]) -> CLIResult {
        guard remaining.first == "test" else {
            return CLIResult(output: renderGenerateHelp(), exitCode: remaining.isEmpty ? 0 : 64)
        }
        let commandArgs = Array(remaining.dropFirst())
        if isHelpRequest(commandArgs) {
            return CLIResult(output: renderGenerateHelp(), exitCode: 0)
        }
        do {
            let options = try parseGenerateTestOptions(args: commandArgs)
            return try runGenerateTestCommand(
                options: options,
                emitters: StudioCodeEmitters(ios: XCUITestEmitter(), android: EspressoEmitter())
            )
        } catch {
            return CLIResult(output: String(describing: error), exitCode: 64)
        }
    }

    private func handleStudioCommand(remaining: [String]) async -> CLIResult {
        if isHelpRequest(remaining) {
            return CLIResult(output: "Usage: amoo studio serve", exitCode: 0)
        }
        guard remaining == ["serve"] else {
            return CLIResult(output: "Usage: amoo studio serve", exitCode: 64)
        }
        let workspace = LiveStudioDeviceWorkspace()
        let automation = LiveStudioAutomationService(
            workspace: workspace,
            toolExecutor: CLIStudioToolExecutor(),
            codeEmitters: StudioCodeEmitters(ios: XCUITestEmitter(), android: EspressoEmitter())
        )
        await StudioService(workspace: workspace, automation: automation).run(output: studioProtocolOutput())
        return CLIResult(output: "", exitCode: 0)
    }

    private func handlePreflightCommand(remaining: [String]) async -> CLIResult {
        if isHelpRequest(remaining) {
            return CLIResult(output: renderPreflightHelp(), exitCode: 0)
        }
        switch parsePreflightPlatform(args: remaining) {
        case let .failure(message):
            return CLIResult(output: message, exitCode: 64)
        case let .success(platform):
            let report = await preflightChecker.run(platform: platform)
            let output = renderPreflightReport(report)
            return CLIResult(output: output, exitCode: report.hasFailures ? 2 : 0)
        }
    }

    private func handleDeviceCommand(remaining: [String]) async -> CLIResult {
        if isHelpRequest(remaining) {
            return CLIResult(output: renderDeviceHelp(), exitCode: 0)
        }
        switch parseDeviceCommandOptions(args: remaining) {
        case let .failure(error):
            return CLIResult(output: error.description, exitCode: 64)
        case let .success(options):
            return await runDeviceCommand(options: options)
        }
    }

    private func handleCompanionCommand(remaining: [String]) async -> CLIResult {
        if isHelpRequest(remaining) {
            return CLIResult(output: renderCompanionHelp(), exitCode: 0)
        }
        switch parseCompanionCommandOptions(args: remaining) {
        case let .failure(error):
            return CLIResult(output: error.description, exitCode: 64)
        case let .success(options):
            return await runCompanionCommand(options: options)
        }
    }

    private func handleFlowCommand(remaining: [String]) async -> CLIResult {
        if isHelpRequest(remaining) || remaining.isEmpty {
            return CLIResult(output: renderFlowHelp(), exitCode: remaining.isEmpty ? 64 : 0)
        }
        guard remaining.count == 1 else {
            return CLIResult(output: renderFlowHelp(), exitCode: 64)
        }
        return await runFlowCommand(path: remaining[0])
    }

    private func handleAuditCommand(remaining: [String]) async -> CLIResult {
        if isHelpRequest(remaining) {
            return CLIResult(output: renderAuditHelp(), exitCode: 0)
        }
        do {
            let options = try parseAuditOptions(args: remaining)
            let execution = try await runAuditCommand(options: options, runner: auditRunner)
            return CLIResult(output: execution.output, exitCode: execution.exitCode)
        } catch let error as AuditCommandParseError {
            return CLIResult(output: error.description, exitCode: 64)
        } catch {
            return CLIResult(output: "Audit command failed: \(error)", exitCode: 1)
        }
    }

    private func handleChatCommand(remaining: [String]) async -> CLIResult {
        if isHelpRequest(remaining) {
            return CLIResult(output: renderChatHelp(), exitCode: 0)
        }
        switch parseChatCommandOptions(args: remaining) {
        case let .failure(error):
            return CLIResult(output: error.description, exitCode: 64)
        case let .success(options):
            return await runChatCommand(options: options)
        }
    }

    private func handleMCPCommand(remaining: [String]) async -> CLIResult {
        if isHelpRequest(remaining) {
            return CLIResult(output: renderMCPHelp(), exitCode: 0)
        }
        return await runMCPCommand(args: remaining)
    }
}

/// Keeps stdout exclusively framed for Studio even when lower-level build or companion code logs
/// with `print`. The protocol retains a duplicate of the original descriptor; ordinary stdout is
/// redirected to stderr for the remainder of this long-lived service process.
private func studioProtocolOutput() -> FileHandle {
    let protocolDescriptor = dup(STDOUT_FILENO)
    precondition(protocolDescriptor >= 0, "Could not duplicate Studio protocol output")
    precondition(dup2(STDERR_FILENO, STDOUT_FILENO) >= 0, "Could not reserve Studio protocol output")
    return FileHandle(fileDescriptor: protocolDescriptor, closeOnDealloc: true)
}

func isHelpToken(_ token: String?) -> Bool {
    matchesHelpToken(token)
}

func isHelpRequest(_ args: [String]) -> Bool {
    guard let first = args.first else { return false }
    if matchesHelpToken(first) {
        return true
    }

    return args.count == 2 && matchesHelpToken(args[1])
}

private func matchesHelpToken(_ token: String?) -> Bool {
    guard let token else { return false }
    return token == "help" || token == "-h" || token == "--help"
}

func renderCLIHelp() -> String {
    """
    Usage: amoo <command> [options]

    Commands:
      help                         Show this help
      preflight [--platform ...]   Check local tooling and environment
      device ...                   Run a device tool against iOS or Android
      companion ...                Build or install a companion app
      flow <path.amoo.json>        Run a reusable checked-in device flow
      audit ...                    Run app audit rules
      chat                         Interactive AI chat (Ollama + MCP tools)
      mcp serve                    Run the local MCP stdio server for AI clients
      studio serve                 Run the Studio JSON-RPC service over stdio

    Shortcuts:
      amoo --help                  Show top-level help
      amoo --tools                 List MCP tool names only (comma-separated)

    Guidance:
      Run 'amoo <command>' without enough arguments to see command-specific usage.
      Examples: 'amoo device', 'amoo companion', 'amoo mcp serve'
    """
}

private enum ParsedPreflightPlatform {
    case success(PreflightPlatform)
    case failure(String)
}

private func parsePreflightPlatform(args: [String]) -> ParsedPreflightPlatform {
    guard !args.isEmpty else {
        return .success(.all)
    }

    guard args.count == 2, args[0] == "--platform" else {
        return .failure("Usage: amoo preflight [--platform ios|android|all]")
    }

    guard let platform = PreflightPlatform(rawValue: args[1].lowercased()) else {
        return .failure("Invalid platform '\(args[1])'. Expected ios, android, or all.")
    }

    return .success(platform)
}

func renderPreflightHelp() -> String {
    "Usage: amoo preflight [--platform ios|android|all]"
}
