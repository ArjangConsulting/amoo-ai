import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import MCPServer
import OllamaClient
import ProcessRunner
import TestSession

struct ChatCommandOptions {
    var model: String
    var platform: Platform
    var port: Int?
    var deviceID: String?
    var ollamaHost: String
    var ollamaPort: Int
    var noCompanion: Bool
}

enum ChatCommandParseError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(msg): msg
        }
    }
}

private struct MutableChatOptions {
    var model = "qwen3.6:latest"
    var platform: Platform = .ios
    var port: Int?
    var deviceID: String?
    var ollamaHost = "127.0.0.1"
    var ollamaPort = 11434
    var noCompanion = false

    var options: ChatCommandOptions {
        ChatCommandOptions(
            model: model,
            platform: platform,
            port: port,
            deviceID: deviceID,
            ollamaHost: ollamaHost,
            ollamaPort: ollamaPort,
            noCompanion: noCompanion
        )
    }
}

/// Applies one `--flag [value]` pair from `args` starting at `index` to `options`, advancing
/// `index` past any consumed value. Returns a parse error instead of mutating on failure.
private func applyChatArgument(
    args: [String],
    index: inout Int,
    options: inout MutableChatOptions
) -> ChatCommandParseError? {
    switch args[index] {
    case "--model", "-m":
        return assignStringOption(args, index: &index, optionName: "--model") { options.model = $0 }
    case "--platform":
        return assignPlatformOption(args, index: &index) { options.platform = $0 }
    case "--port":
        return assignIntOption(args, index: &index, optionName: "--port") { options.port = $0 }
    case "--device":
        return assignStringOption(args, index: &index, optionName: "--device") { options.deviceID = $0 }
    case "--ollama-host":
        return assignStringOption(args, index: &index, optionName: "--ollama-host") { options.ollamaHost = $0 }
    case "--ollama-port":
        return assignIntOption(args, index: &index, optionName: "--ollama-port") { options.ollamaPort = $0 }
    case "--no-companion":
        options.noCompanion = true
        return nil
    default:
        return .invalid("Unknown option: \(args[index])")
    }
}

private func assignStringOption(
    _ args: [String],
    index: inout Int,
    optionName: String,
    assign: (String) -> Void
) -> ChatCommandParseError? {
    index += 1
    guard index < args.count else { return .invalid("\(optionName) requires a value") }
    assign(args[index])
    return nil
}

private func assignIntOption(
    _ args: [String],
    index: inout Int,
    optionName: String,
    assign: (Int) -> Void
) -> ChatCommandParseError? {
    index += 1
    guard index < args.count, let value = Int(args[index]) else {
        return .invalid("\(optionName) requires an integer value")
    }
    assign(value)
    return nil
}

private func assignPlatformOption(
    _ args: [String],
    index: inout Int,
    assign: (Platform) -> Void
) -> ChatCommandParseError? {
    index += 1
    guard index < args.count else { return .invalid("--platform requires a value") }
    guard let platform = Platform(rawValue: args[index].lowercased()) else {
        return .invalid("Invalid platform '\(args[index])'. Use ios or android.")
    }
    assign(platform)
    return nil
}

func parseChatCommandOptions(args: [String]) -> Result<ChatCommandOptions, ChatCommandParseError> {
    var mutableOptions = MutableChatOptions()

    var i = 0
    while i < args.count {
        if let error = applyChatArgument(args: args, index: &i, options: &mutableOptions) {
            return .failure(error)
        }
        i += 1
    }

    return .success(mutableOptions.options)
}

/// Lightweight success/failure result for chat setup steps that fail with a `CLIResult`
/// (a plain struct, not an `Error`) rather than throwing.
private enum ChatStepResult<Success> {
    case success(Success)
    case failure(CLIResult)
}

// MARK: - Run

func runChatCommand(options: ChatCommandOptions) async -> CLIResult {
    let companionPort = options.port ?? defaultChatPort(for: options.platform)

    let ollama: OllamaClient
    switch await prepareOllamaClient(options: options) {
    case let .success(client): ollama = client
    case let .failure(result): return result
    }

    let device: AvailableDevice
    switch await selectChatDevice(options: options) {
    case let .success(selected): device = selected
    case let .failure(result): return result
    }

    let resolvedDeviceID: String = switch device {
    case let .ios(booted): booted.udid
    case let .android(serial, _): serial
    }

    if let earlyExit = await ensureChatCompanionReady(
        options: options,
        companionPort: companionPort,
        resolvedDeviceID: resolvedDeviceID
    ) {
        return earlyExit
    }

    let driver: any PlatformDriver
    switch await makeChatDriver(options: options, companionPort: companionPort, resolvedDeviceID: resolvedDeviceID) {
    case let .success(created): driver = created
    case let .failure(result): return result
    }

    let sessionManager = SessionManager(
        bootstrapper: DefaultSessionBootstrapper(
            iOSCompanionManager: CompanionManager(),
            androidCompanionManager: AndroidCompanionManager()
        ),
        store: FileSessionStore()
    )
    let executor = DriverToolExecutor(
        driver: driver,
        sessionManager: sessionManager,
        foreignBuildDetector: ForeignBuildDetector()
    )
    let server = MCPServer(executor: executor, sessionManager: sessionManager)

    let systemPrompt = """
    You are an AI assistant for mobile app testing using the amoo framework.
    You have access to tools that control \(options.platform == .ios ? "iOS" : "Android") devices/simulators.

    When the user asks you to perform actions on the device, use the available tools.
    Always explain what you're doing and report results clearly.
    If a tool call fails, explain the error and suggest fixes.

    Be concise in your responses. Prefer taking action over asking for clarification when the intent is clear.
    """

    var chatLoop = ChatLoop(
        executor: executor,
        ollamaClient: ollama,
        toolDefinitions: server.toolDefinitions(),
        model: options.model,
        systemPrompt: systemPrompt
    )

    await chatLoop.run()
    return CLIResult(output: "", exitCode: 0)
}

/// Confirms Ollama is reachable and the requested model is available, printing status as it goes.
private func prepareOllamaClient(options: ChatCommandOptions) async -> ChatStepResult<OllamaClient> {
    print(colored("Checking Ollama...", .gray), terminator: " ")
    fflush(nil)
    let ollama = OllamaClient(host: options.ollamaHost, port: options.ollamaPort)
    guard await ollama.isAvailable() else {
        print(colored("✗", .red))
        return .failure(CLIResult(
            output: "Cannot connect to Ollama at \(options.ollamaHost):\(options.ollamaPort).\n"
                + "Make sure Ollama is running: ollama serve",
            exitCode: 1
        ))
    }
    print(colored("✓", .green) + colored(" (\(options.model))", .gray))

    do {
        let models = try await ollama.listModels()
        let modelBase = options.model.split(separator: ":").first.map(String.init) ?? options.model
        if !models.contains(where: { $0.hasPrefix(modelBase) || $0 == options.model }) {
            let available = models.prefix(10).joined(separator: ", ")
            return .failure(CLIResult(
                output: "Model '\(options.model)' not found. Available: \(available)\n"
                    + "Pull it with: ollama pull \(options.model)",
                exitCode: 1
            ))
        }
    } catch {
        // Non-fatal — proceed anyway.
    }

    return .success(ollama)
}

private func selectChatDevice(options: ChatCommandOptions) async -> ChatStepResult<AvailableDevice> {
    let selector = PlatformDeviceSelector()
    do {
        let device = try await selector.selectDevice(hint: options.deviceID, platform: options.platform)
        return .success(device)
    } catch let error as DeviceSelectionError {
        return .failure(CLIResult(output: error.description, exitCode: 1))
    } catch {
        return .failure(CLIResult(output: "Device selection failed: \(error)", exitCode: 1))
    }
}

/// Checks companion reachability (unless `--no-companion`), offering to install and launch it
/// when unreachable. Returns a non-nil `CLIResult` only when the caller should exit immediately.
private func ensureChatCompanionReady(
    options: ChatCommandOptions,
    companionPort: Int,
    resolvedDeviceID: String
) async -> CLIResult? {
    guard !options.noCompanion else { return nil }

    print(colored("Checking companion on 127.0.0.1:\(companionPort)...", .gray), terminator: " ")
    fflush(nil)

    guard await isCompanionReachable(host: "127.0.0.1", port: companionPort) else {
        return await promptToInstallCompanion(
            options: options,
            companionPort: companionPort,
            resolvedDeviceID: resolvedDeviceID
        )
    }
    print(colored("✓", .green))
    return nil
}

private func promptToInstallCompanion(
    options: ChatCommandOptions,
    companionPort: Int,
    resolvedDeviceID: String
) async -> CLIResult? {
    print(colored("✗", .red))
    print()
    print(colored("Companion app not running.", .yellow))
    print(
        "Install and launch companion for \(options.platform == .ios ? "iOS" : "Android")? [Y/n] ",
        terminator: ""
    )
    fflush(nil)

    let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y"
    guard answer.isEmpty || answer == "y" || answer == "yes" else {
        print(colored("  Skipping companion. Some tools may fail.", .yellow))
        return nil
    }

    let installResult = await installAndLaunchCompanion(
        platform: options.platform,
        port: companionPort,
        deviceID: resolvedDeviceID
    )
    switch installResult {
    case .success:
        print(colored("  ✓ Companion running on port \(companionPort)", .green))
        return nil
    case let .failure(error):
        print(colored("  ✗ \(error)", .red))
        print()
        print("Troubleshooting:")
        print("  1. Ensure a simulator is booted: xcrun simctl list devices booted")
        print("  2. Try rebuilding: amoo companion install --platform \(options.platform.rawValue) --force")
        print("  3. Check logs: cat $TMPDIR/companion-launch.log")
        print("  4. Use --no-companion to skip and debug manually")
        return CLIResult(output: "", exitCode: 1)
    }
}

private func makeChatDriver(
    options: ChatCommandOptions,
    companionPort: Int,
    resolvedDeviceID: String
) async -> ChatStepResult<any PlatformDriver> {
    let connection = CompanionConnection(host: "127.0.0.1", port: companionPort)
    do {
        let companion = try GRPCCompanionClient.makeLive(connection: connection)
        switch options.platform {
        case .ios:
            return await .success(makeIOSDriver(companion: companion, deviceID: resolvedDeviceID))
        case .android:
            return .success(AndroidDriver(
                companion: companion,
                inspectionMode: .productionDefault(),
                serial: resolvedDeviceID
            ))
        }
    } catch {
        return .failure(CLIResult(output: "Failed to create driver: \(error)", exitCode: 1))
    }
}

// MARK: - Companion Reachability

private func isCompanionReachable(host: String, port: Int) async -> Bool {
    await isTCPPortReachable(host: host, port: port, timeoutSeconds: 2.0)
}

// MARK: - Companion Install + Launch

private func installAndLaunchCompanion(
    platform: Platform,
    port: Int,
    deviceID: String
) async -> Result<Void, ChatCommandParseError> {
    switch platform {
    case .ios:
        let manager = CompanionManager()
        let config = CompanionConfig(port: port, deviceUDID: deviceID)
        do {
            try await manager.ensureRunning(config: config)
            return .success(())
        } catch {
            return .failure(.invalid("\(error)"))
        }
    case .android:
        let manager = AndroidCompanionManager()
        let config = AndroidCompanionConfig(port: port, serial: deviceID)
        do {
            try await manager.ensureRunning(config: config)
            return .success(())
        } catch {
            return .failure(.invalid("\(error)"))
        }
    }
}

// MARK: - Helpers

private func defaultChatPort(for platform: Platform) -> Int {
    switch platform {
    case .ios: 22087
    case .android: 22088
    }
}

// MARK: - Help

func renderChatHelp() -> String {
    """
    Usage: amoo chat [options]

    Start an interactive AI chat session that can control devices via MCP tools.

    Options:
      --model, -m <name>       Ollama model to use (default: qwen3.6:latest)
      --platform <ios|android> Target platform (default: ios)
      --port <port>            Companion gRPC port (default: 22087 iOS, 22088 Android)
      --device <id>            Device/simulator ID
      --ollama-host <host>     Ollama host (default: 127.0.0.1)
      --ollama-port <port>     Ollama port (default: 11434)
      --no-companion           Skip companion check (tools may fail)

    In-chat commands:
      /tools    - List available tools with descriptions
      /history  - Show conversation
      /clear    - Reset conversation
      /model    - Show current model
      /quit     - Exit

    Examples:
      amoo chat
      amoo chat --model llama3.1:8b --platform android
      amoo chat --model qwen3:32b --device "iPhone 16 Pro"
      amoo chat --no-companion
    """
}
