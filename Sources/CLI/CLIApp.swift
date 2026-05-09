import AuditEngine
import MCPServer
import MobileTestingCore

public struct CLIResult: Sendable, Equatable {
    public var output: String
    public var exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public struct CLIApp {
    private let mcpServer: MCPServer
    private let preflightChecker: any PreflightChecking
    private let auditRunner: any AuditRunning
    private let aiStatusChecker: any AIStatusChecking
    private let aiSetupWizard: AISetupWizard
    private let aiResolver: AIConfigurationResolver
    private let aiSettingsStore: any AISettingsStore

    public init(
        mcpServer: MCPServer = .init(),
        preflightChecker: any PreflightChecking = DefaultPreflightChecker(),
        auditRunner: any AuditRunning = DefaultAuditRunner(),
        aiStatusChecker: any AIStatusChecking = DefaultAIStatusChecker(),
        aiSetupWizard: AISetupWizard = AISetupWizard(),
        aiResolver: AIConfigurationResolver = AIConfigurationResolver(),
        aiSettingsStore: any AISettingsStore = FileAISettingsStore()
    ) {
        self.mcpServer = mcpServer
        self.preflightChecker = preflightChecker
        self.auditRunner = auditRunner
        self.aiStatusChecker = aiStatusChecker
        self.aiSetupWizard = aiSetupWizard
        self.aiResolver = aiResolver
        self.aiSettingsStore = aiSettingsStore
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func run(args: [String]) async -> CLIResult {
        if args.contains("--tools") {
            return CLIResult(output: mcpServer.toolNames().joined(separator: ","), exitCode: 0)
        }

        if args.first == "preflight" {
            let parsed = parsePreflightPlatform(args: Array(args.dropFirst()))
            switch parsed {
            case let .failure(message):
                return CLIResult(output: message, exitCode: 64)
            case let .success(platform):
                let report = await preflightChecker.run(platform: platform)
                let output = renderPreflightReport(report)
                return CLIResult(output: output, exitCode: report.hasFailures ? 2 : 0)
            }
        }

        if args.first == "device" {
            switch parseDeviceCommandOptions(args: Array(args.dropFirst())) {
            case let .failure(error):
                return CLIResult(output: error.description, exitCode: 64)
            case let .success(options):
                return await runDeviceCommand(options: options)
            }
        }

        if args.first == "companion" {
            switch parseCompanionCommandOptions(args: Array(args.dropFirst())) {
            case let .failure(error):
                return CLIResult(output: error.description, exitCode: 64)
            case let .success(options):
                return await runCompanionCommand(options: options)
            }
        }

        if args.first == "audit" {
            do {
                let options = try parseAuditOptions(args: Array(args.dropFirst()))
                let execution = try await runAuditCommand(options: options, runner: auditRunner)
                return CLIResult(output: execution.output, exitCode: execution.exitCode)
            } catch let error as AuditCommandParseError {
                return CLIResult(output: error.description, exitCode: 64)
            } catch {
                return CLIResult(output: "Audit command failed: \(error)", exitCode: 1)
            }
        }

        if args.first == "ai" {
            switch parseAICommand(args: Array(args.dropFirst())) {
            case let .failure(error):
                return CLIResult(output: error.description, exitCode: 64)
            case .success(.status):
                return await runAIStatusCommand(checker: aiStatusChecker)
            case .success(.setup):
                do {
                    let result = try await aiSetupWizard.runPersistentSetup()
                    let output = if result.shouldPersist {
                        if let fileStore = aiSettingsStore as? FileAISettingsStore {
                            "Saved AI settings to \(fileStore.path)\nprovider: \(result.configuration.provider.rawValue)"
                        } else {
                            "Saved AI settings.\nprovider: \(result.configuration.provider.rawValue)"
                        }
                    } else {
                        "No AI settings were saved."
                    }
                    return CLIResult(output: output, exitCode: 0)
                } catch let error as AISetupError {
                    return CLIResult(output: error.description, exitCode: 1)
                } catch {
                    return CLIResult(output: "AI setup failed: \(error)", exitCode: 1)
                }
            case .success(.config):
                let configuration = (try? aiResolver.resolve()) ?? ResolvedAIConfiguration(provider: .disabled, source: "default")
                return CLIResult(output: renderAIConfig(configuration), exitCode: 0)
            case .success(.reset):
                do {
                    try aiSettingsStore.reset()
                    return CLIResult(output: "AI settings reset.", exitCode: 0)
                } catch {
                    return CLIResult(output: "Failed to reset AI settings: \(error)", exitCode: 1)
                }
            }
        }

        // Default: interactive REPL mode
        await startREPLMode(args: args)
        return CLIResult(output: "", exitCode: 0)
    }
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
