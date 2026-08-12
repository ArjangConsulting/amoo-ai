import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import MCPServer
import Network
import OllamaClient
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

func parseChatCommandOptions(args: [String]) -> Result<ChatCommandOptions, ChatCommandParseError> {
    var model = "qwen3.6:latest"
    var platform: Platform = .ios
    var port: Int?
    var deviceID: String?
    var ollamaHost = "127.0.0.1"
    var ollamaPort = 11434
    var noCompanion = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--model", "-m":
            i += 1
            guard i < args.count else { return .failure(.invalid("--model requires a value")) }
            model = args[i]
        case "--platform":
            i += 1
            guard i < args.count else { return .failure(.invalid("--platform requires a value")) }
            guard let p = Platform(rawValue: args[i].lowercased()) else {
                return .failure(.invalid("Invalid platform '\(args[i])'. Use ios or android."))
            }
            platform = p
        case "--port":
            i += 1
            guard i < args.count, let p = Int(args[i]) else {
                return .failure(.invalid("--port requires an integer value"))
            }
            port = p
        case "--device":
            i += 1
            guard i < args.count else { return .failure(.invalid("--device requires a value")) }
            deviceID = args[i]
        case "--ollama-host":
            i += 1
            guard i < args.count else { return .failure(.invalid("--ollama-host requires a value")) }
            ollamaHost = args[i]
        case "--ollama-port":
            i += 1
            guard i < args.count, let p = Int(args[i]) else {
                return .failure(.invalid("--ollama-port requires an integer value"))
            }
            ollamaPort = p
        case "--no-companion":
            noCompanion = true
        default:
            return .failure(.invalid("Unknown option: \(args[i])"))
        }
        i += 1
    }

    return .success(ChatCommandOptions(
        model: model,
        platform: platform,
        port: port,
        deviceID: deviceID,
        ollamaHost: ollamaHost,
        ollamaPort: ollamaPort,
        noCompanion: noCompanion
    ))
}

// MARK: - Run

func runChatCommand(options: ChatCommandOptions) async -> CLIResult {
    let companionPort = options.port ?? defaultChatPort(for: options.platform)

    // 1. Check Ollama availability
    print(colored("Checking Ollama...", .gray), terminator: " ")
    fflush(stdout)
    let ollama = OllamaClient(host: options.ollamaHost, port: options.ollamaPort)
    guard await ollama.isAvailable() else {
        print(colored("✗", .red))
        return CLIResult(
            output: "Cannot connect to Ollama at \(options.ollamaHost):\(options.ollamaPort).\n"
                + "Make sure Ollama is running: ollama serve",
            exitCode: 1
        )
    }
    print(colored("✓", .green) + colored(" (\(options.model))", .gray))

    // 2. Verify model exists
    do {
        let models = try await ollama.listModels()
        let modelBase = options.model.split(separator: ":").first.map(String.init) ?? options.model
        if !models.contains(where: { $0.hasPrefix(modelBase) || $0 == options.model }) {
            let available = models.prefix(10).joined(separator: ", ")
            return CLIResult(
                output: "Model '\(options.model)' not found. Available: \(available)\n"
                    + "Pull it with: ollama pull \(options.model)",
                exitCode: 1
            )
        }
    } catch {
        // Non-fatal — proceed anyway.
    }

    // 3. Select device
    let selector = PlatformDeviceSelector()
    let device: AvailableDevice
    do {
        device = try await selector.selectDevice(hint: options.deviceID, platform: options.platform)
    } catch let error as DeviceSelectionError {
        return CLIResult(output: error.description, exitCode: 1)
    } catch {
        return CLIResult(output: "Device selection failed: \(error)", exitCode: 1)
    }

    let resolvedDeviceID: String = switch device {
    case let .ios(booted): booted.udid
    case let .android(serial, _): serial
    }

    // 4. Check companion reachability (unless --no-companion)
    if !options.noCompanion {
        print(colored("Checking companion on 127.0.0.1:\(companionPort)...", .gray), terminator: " ")
        fflush(stdout)

        let reachable = await isCompanionReachable(host: "127.0.0.1", port: companionPort)
        if reachable {
            print(colored("✓", .green))
        } else {
            print(colored("✗", .red))
            print()
            print(colored("Companion app not running.", .yellow))
            print(
                "Install and launch companion for \(options.platform == .ios ? "iOS" : "Android")? [Y/n] ",
                terminator: ""
            )
            fflush(stdout)

            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "y"
            if answer.isEmpty || answer == "y" || answer == "yes" {
                let installResult = await installAndLaunchCompanion(
                    platform: options.platform,
                    port: companionPort,
                    deviceID: resolvedDeviceID
                )
                switch installResult {
                case .success:
                    print(colored("  ✓ Companion running on port \(companionPort)", .green))
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
            } else {
                print(colored("  Skipping companion. Some tools may fail.", .yellow))
            }
        }
    }

    // 5. Set up device driver
    let connection = CompanionConnection(host: "127.0.0.1", port: companionPort)
    let driver: any PlatformDriver
    do {
        let companion = try GRPCCompanionClient.makeLive(connection: connection)
        switch options.platform {
        case .ios:
            driver = await makeIOSDriver(companion: companion, deviceID: resolvedDeviceID)
        case .android:
            driver = AndroidDriver(companion: companion, serial: resolvedDeviceID)
        }
    } catch {
        return CLIResult(output: "Failed to create driver: \(error)", exitCode: 1)
    }

    let sessionManager = SessionManager(bootstrapper: DefaultSessionBootstrapper(
        iOSCompanionManager: CompanionManager(),
        androidCompanionManager: AndroidCompanionManager()
    ))
    let executor = DriverToolExecutor(driver: driver, sessionManager: sessionManager)
    let server = MCPServer(executor: executor, sessionManager: sessionManager)

    // 6. Build system prompt
    let systemPrompt = """
    You are an AI assistant for mobile app testing using the amoo framework.
    You have access to tools that control \(options.platform == .ios ? "iOS" : "Android") devices/simulators.

    When the user asks you to perform actions on the device, use the available tools.
    Always explain what you're doing and report results clearly.
    If a tool call fails, explain the error and suggest fixes.

    Be concise in your responses. Prefer taking action over asking for clarification when the intent is clear.
    """

    // 7. Start chat loop
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

// MARK: - Companion Reachability

/// Thread-safe one-shot continuation box for reachability checks.
private final class ChatReachabilityBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var resolved = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation.resume(returning: value)
    }
}

private func isCompanionReachable(host: String, port: Int) async -> Bool {
    await withCheckedContinuation { continuation in
        let box = ChatReachabilityBox(continuation: continuation)
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.cancel()
                box.resolve(true)
            case .failed, .cancelled:
                box.resolve(false)
            default:
                break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            connection.cancel()
            box.resolve(false)
        }
    }
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
