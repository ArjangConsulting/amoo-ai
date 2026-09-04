import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import MCPServer
import ProcessRunner
import TestSession

enum MCPCommandParseError: Error, CustomStringConvertible {
    case missingAction
    case unknownAction(String)
    case malformedArguments
    case invalidPort(String)
    case missingValue(String)
    case unknownOption(String)
    case unknownPlatform(String)

    var description: String {
        switch self {
        case .missingAction:
            renderMCPHelp()
        case let .unknownAction(action):
            "Unknown mcp action '\(action)'. Run 'amoo mcp --help' for usage."
        case .malformedArguments:
            renderMCPHelp()
        case let .invalidPort(value):
            "Invalid port '\(value)'. Expected a number."
        case let .missingValue(option):
            "Missing value for \(option)."
        case let .unknownOption(option):
            "Unknown option '\(option)'."
        case let .unknownPlatform(value):
            "Unknown platform '\(value)'. Expected 'ios' or 'android'."
        }
    }
}

struct MCPServeOptions: Sendable, Equatable {
    var platform: Platform
    var port: Int
    var deviceID: String?
}

func renderMCPHelp() -> String {
    "Usage: amoo mcp serve [--platform ios|android] [--port <port>] [--device <id>]"
}

func runMCPCommand(args: [String]) async -> CLIResult {
    guard let action = args.first else {
        return CLIResult(output: MCPCommandParseError.missingAction.description, exitCode: 64)
    }

    guard action == "serve" else {
        return CLIResult(output: MCPCommandParseError.unknownAction(action).description, exitCode: 64)
    }

    switch parseMCPServeOptions(args: Array(args.dropFirst())) {
    case let .failure(error):
        return CLIResult(output: error.description, exitCode: 64)
    case let .success(options):
        return await runMCPServeCommand(options: options)
    }
}

private struct MCPServeFlags {
    var platform: Platform = .ios
    var port: Int?
    var deviceID: String?
}

/// Applies one recognized `--flag value` pair to `flags`, consuming both tokens from
/// `remaining`. `first` must already be known to have the `--` prefix.
private func applyMCPServeFlag(
    _ first: String,
    remaining: inout [String],
    flags: inout MCPServeFlags
) -> MCPCommandParseError? {
    switch first {
    case "--platform":
        remaining.removeFirst()
        guard let value = remaining.first else { return .missingValue("--platform") }
        guard let parsed = Platform(rawValue: value.lowercased()) else { return .unknownPlatform(value) }
        flags.platform = parsed
        remaining.removeFirst()
    case "--port":
        remaining.removeFirst()
        guard let value = remaining.first else { return .missingValue("--port") }
        guard let parsed = Int(value) else { return .invalidPort(value) }
        flags.port = parsed
        remaining.removeFirst()
    case "--device":
        remaining.removeFirst()
        guard let value = remaining.first else { return .missingValue("--device") }
        flags.deviceID = value
        remaining.removeFirst()
    default:
        return .unknownOption(first)
    }
    return nil
}

func parseMCPServeOptions(args: [String]) -> Result<MCPServeOptions, MCPCommandParseError> {
    var remaining = args
    var flags = MCPServeFlags()

    while let first = remaining.first {
        guard first.hasPrefix("--") else {
            return .failure(.malformedArguments)
        }
        if let error = applyMCPServeFlag(first, remaining: &remaining, flags: &flags) {
            return .failure(error)
        }
    }

    return .success(MCPServeOptions(
        platform: flags.platform,
        port: flags.port ?? defaultMCPPort(for: flags.platform),
        deviceID: normalizedMCPDeviceID(flags.deviceID, for: flags.platform)
    ))
}

func runMCPServeCommand(options: MCPServeOptions) async -> CLIResult {
    do {
        let connection = CompanionConnection(host: "127.0.0.1", port: options.port)
        let companion = try GRPCCompanionClient.makeLive(connection: connection)
        let driver: any PlatformDriver = switch options.platform {
        case .ios:
            await makeIOSDriver(companion: companion, deviceID: options.deviceID ?? "booted")
        case .android:
            AndroidDriver(
                companion: companion,
                inspectionMode: .productionDefault(),
                serial: options.deviceID
            )
        }

        // Wire up session management so `start_session` can boot devices,
        // build/launch the companion, install + launch the app on demand.
        let iOSCM = CompanionManager()
        let androidCM = AndroidCompanionManager()
        let bootstrapper = DefaultSessionBootstrapper(
            iOSCompanionManager: iOSCM,
            androidCompanionManager: androidCM
        )
        let sessionManager = SessionManager(bootstrapper: bootstrapper, store: FileSessionStore())
        let executor = DriverToolExecutor(
            driver: driver,
            sessionManager: sessionManager,
            foreignBuildDetector: ForeignBuildDetector(),
            webInspector: makeWebInspecting(processRunner: SystemProcessRunner())
        )
        let server = MCPServer(executor: executor, sessionManager: sessionManager)

        do {
            try await MCPStdioServer(server: server).run()
        } catch {
            await sessionManager.closeAll()
            await iOSCM.shutdown()
            await androidCM.shutdown()
            await companion.shutdown()
            throw error
        }

        await sessionManager.closeAll()
        await iOSCM.shutdown()
        await androidCM.shutdown()
        await companion.shutdown()
        return CLIResult(output: "", exitCode: 0)
    } catch {
        writeMCPError("MCP server failed: \(error)")
        return CLIResult(output: "", exitCode: 1)
    }
}

private func writeMCPError(_ message: String) {
    let line = message + "\n"
    FileHandle.standardError.write(Data(line.utf8))
}

private func defaultMCPPort(for platform: Platform) -> Int {
    switch platform {
    case .ios: 22087
    case .android: 22088
    }
}

private func normalizedMCPDeviceID(_ deviceID: String?, for platform: Platform) -> String? {
    switch platform {
    case .ios:
        return deviceID ?? "booted"
    case .android:
        guard let deviceID, !deviceID.isEmpty, deviceID != "booted" else { return nil }
        return deviceID
    }
}
