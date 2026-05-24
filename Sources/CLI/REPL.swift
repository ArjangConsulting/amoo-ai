import AndroidDriver
import CLIReadline
import CompanionProtocol
import Darwin
import Foundation
import IOSDriver
import MCPServer
import MobileTestingCore

// MARK: - REPL entry point

func runREPL(device: AvailableDevice, port: Int) async {
    switch device {
    case let .ios(bootedDevice):
        await runIOSREPL(device: bootedDevice, port: port)
    case let .android(serial, name):
        await runAndroidREPL(
            serial: serial,
            name: name,
            port: port
        )
    }
}

private func runIOSREPL(device: BootedDevice, port: Int) async {
    let manager = CompanionManager()
    let config = CompanionConfig(port: port, deviceUDID: device.udid)

    do {
        try await manager.ensureRunning(config: config)
    } catch {
        print("Failed to install/start companion: \(error)")
        return
    }

    let connection = CompanionConnection(host: "127.0.0.1", port: port)
    let companion: GRPCCompanionClient
    do {
        companion = try GRPCCompanionClient.makeLive(connection: connection)
    } catch {
        print("Failed to connect to companion: \(error)")
        return
    }

    let driver = IOSDriver(companion: companion, deviceID: device.udid)
    let executor = DriverToolExecutor(driver: driver)
    let mcpServer = MCPServer()
    let toolDefinitions = mcpServer.toolDefinitions()
    REPLCompletionCatalog(toolDefinitions: toolDefinitions).install()

    print("")
    print(colored("Connected to \(device.displayName)", .bold, .green) + " on port \(port)")
    print(colored("Type 'help' for available commands, 'quit' to exit, and press Tab to complete.", .gray))
    print("")

    await replLoop(executor: executor, screenshotHandler: { args in
        await handleIOSScreenshot(driver: driver, arguments: args)
    }, toolDefinitions: toolDefinitions)

    await companion.shutdown()
    await manager.shutdown()
}

private func runAndroidREPL(
    serial: String,
    name: String,
    port: Int
) async {
    let connection = CompanionConnection(host: "127.0.0.1", port: port)
    let companion: GRPCCompanionClient
    do {
        companion = try GRPCCompanionClient.makeLive(connection: connection)
    } catch {
        print("Failed to connect to Android companion on port \(port): \(error)")
        print(colored("Hint: ensure the Android companion is running and port \(port) is forwarded via adb.", .gray))
        return
    }

    let driver = AndroidDriver(companion: companion, serial: serial.isEmpty ? nil : serial)
    let executor = DriverToolExecutor(driver: driver)
    let mcpServer = MCPServer()
    let toolDefinitions = mcpServer.toolDefinitions()
    REPLCompletionCatalog(toolDefinitions: toolDefinitions).install()

    print("")
    print(colored("Connected to \(name) (\(serial))", .bold, .green) + " on port \(port)")
    print(colored("Type 'help' for available commands, 'quit' to exit, and press Tab to complete.", .gray))
    print("")

    await replLoop(executor: executor, screenshotHandler: { args in
        await handleAndroidScreenshot(driver: driver, arguments: args)
    }, toolDefinitions: toolDefinitions)

    await companion.shutdown()
}

// MARK: - Main loop

private func replHistoryPath() -> String? {
    // Avoid falling back to "" + "/.amoo-history" → "/.amoo-history"
    // when HOME is unset (sandboxed CI agents, launchd-managed processes).
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard !home.isEmpty, home != "/" else { return nil }
    return home + "/.amoo-history"
}

private func replLoop(
    executor: DriverToolExecutor,
    screenshotHandler: @escaping @Sendable ([String: String]) async -> Void,
    toolDefinitions: [ToolDefinition]
) async {
    // Load history from previous sessions
    let historyPath = replHistoryPath()
    if let historyPath {
        cli_load_history(historyPath)
    }

    while true {
        // cli_readline blocks — run off the cooperative thread pool
        let line = await Task.detached(priority: .userInitiated) {
            guard let ptr = cli_readline("> ") else { return String?.none }
            defer { free(ptr) }
            return String(cString: ptr)
        }.value

        guard let line else { break } // EOF / Ctrl+D

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        let builtinResult = await handleBuiltin(trimmed, toolDefinitions: toolDefinitions)
        if builtinResult == .quit {
            break
        }
        if builtinResult == .handled {
            continue
        }

        await dispatch(
            line: trimmed,
            executor: executor,
            screenshotHandler: screenshotHandler,
            toolDefinitions: toolDefinitions
        )
    }
}

private struct REPLBannerStyle {
    let topLeft: String
    let topRight: String
    let bottomLeft: String
    let bottomRight: String
    let horizontal: String
    let vertical: String
}

private func replBannerStyle(environment: [String: String] = ProcessInfo.processInfo.environment) -> REPLBannerStyle {
    if supportsUnicodeBanner(environment: environment) {
        return REPLBannerStyle(
            topLeft: "╭",
            topRight: "╮",
            bottomLeft: "╰",
            bottomRight: "╯",
            horizontal: "─",
            vertical: "│"
        )
    }

    return REPLBannerStyle(
        topLeft: "+",
        topRight: "+",
        bottomLeft: "+",
        bottomRight: "+",
        horizontal: "-",
        vertical: "|"
    )
}

private func supportsUnicodeBanner(environment: [String: String]) -> Bool {
    if environment["TERM"]?.lowercased() == "dumb" {
        return false
    }

    let localeValues = [environment["LC_ALL"], environment["LC_CTYPE"], environment["LANG"]]
        .compactMap { $0?.uppercased() }

    if localeValues.contains(where: { $0.contains("UTF-8") || $0.contains("UTF8") }) {
        return true
    }

    return false
}

private func padRight(_ value: String, to width: Int) -> String {
    guard value.count < width else { return value }
    return value + String(repeating: " ", count: width - value.count)
}

// MARK: - Built-in commands

private enum BuiltinCommandResult {
    case handled
    case quit
    case notHandled
}

private func handleBuiltin(_ line: String, toolDefinitions: [ToolDefinition]) async -> BuiltinCommandResult {
    let lower = line.lowercased()

    switch lower {
    case "quit", "exit":
        if let historyPath = replHistoryPath() {
            cli_save_history(historyPath)
        }
        print(colored("Goodbye.", .cyan))
        return .quit

    case "help", "?":
        printHelp(definitions: toolDefinitions)
        return .handled

    case "tools":
        let names = toolDefinitions.map(\.name).joined(separator: ", ")
        print(names)
        return .handled

    default:
        return .notHandled
    }
}

private func printHelp(definitions: [ToolDefinition]) {
    print("")
    print(colored("Available tools", .bold, .cyan) + colored(" (use: <tool_name> [key=value ...])", .gray))
    print("")

    let sorted = definitions.sorted { $0.name < $1.name }
    for def in sorted {
        let reqArgs = def.required.isEmpty ? "" : colored(" (\(def.required.joined(separator: ", ")))", .yellow)
        print("  \(colored(def.name, .green))\(reqArgs)")
        print("    \(colored(def.description, .gray))")
    }

    print("")
    print(colored("Built-in commands:", .bold, .cyan))
    print("  \(colored("help", .green))        Show this help")
    print("  \(colored("tools", .green))       Print available tool names only")
    print("  \(colored("quit/exit", .green))   Exit the session")
    print("")
    print(colored("Press Tab to complete the tool command or argument key.", .gray))
    print("")
}

// MARK: - Dispatch

// swiftlint:disable:next cyclomatic_complexity
private func dispatch(
    line: String,
    executor: DriverToolExecutor,
    screenshotHandler: @escaping @Sendable ([String: String]) async -> Void,
    toolDefinitions: [ToolDefinition]
) async {
    let (toolName, parts) = shellSplit(line)
    guard let toolName else { return }

    // Parse arguments: key=value pairs and positional values
    var arguments: [String: String] = [:]
    var positionalValues: [String] = []
    for part in parts {
        let kv = part.split(separator: "=", maxSplits: 1)
        if kv.count == 2 {
            arguments[String(kv[0])] = String(kv[1])
        } else {
            positionalValues.append(part)
        }
    }

    // Map positional values to the tool's first required argument, or a sensible default
    if !positionalValues.isEmpty {
        let positionalText = positionalValues.joined(separator: " ")
        if let def = toolDefinitions.first(where: { $0.name == toolName }) {
            if let firstRequired = def.required.first, arguments[firstRequired] == nil {
                arguments[firstRequired] = positionalText
            } else if def.properties.keys.contains("label"), arguments["label"] == nil {
                arguments["label"] = positionalText
            } else if def.properties.keys.contains("contains_text"), arguments["contains_text"] == nil {
                arguments["contains_text"] = positionalText
            } else if def.properties.keys.contains("text"), arguments["text"] == nil {
                arguments["text"] = positionalText
            } else if let firstProp = def.properties.keys.sorted().first, arguments[firstProp] == nil {
                arguments[firstProp] = positionalText
            }
        }
    }

    // Screenshot: save bytes to a file
    if toolName == "take_screenshot" {
        await withCLILoadingIndicator("Capturing screenshot") {
            await screenshotHandler(arguments)
        }
        return
    }

    let result = await withCLILoadingIndicator("Running \(toolName)") {
        await executor.execute(toolName: toolName, arguments: arguments)
    }
    if result.isError {
        print(colored(result.content, .red))
        if result.content.hasPrefix("Unknown tool") {
            if let suggestion = closestTool(to: toolName, among: toolDefinitions.map(\.name)) {
                print(colored("Did you mean: ", .gray) + colored(suggestion, .green) + colored("?", .gray))
            }
        }
    } else if result.content.contains("\u{001B}[") {
        // Already contains ANSI color codes (e.g. view hierarchy) — print as-is
        print(result.content)
    } else {
        print(colored(result.content, .green))
    }
}

private func handleIOSScreenshot(driver: IOSDriver, arguments: [String: String]) async {
    do {
        let requestedFormat = arguments["format"]?.lowercased()
        let format: ImageFormat = requestedFormat == "jpeg" ? .jpeg : .png
        let fileExtension = format == .jpeg ? "jpeg" : "png"
        let data = try await driver.takeScreenshot(format: format)
        let outputPath: String
        if let path = arguments["output"] {
            outputPath = path
        } else {
            let timestamp = Int(Date().timeIntervalSince1970)
            outputPath = FileManager.default.currentDirectoryPath + "/screenshot_\(timestamp).\(fileExtension)"
        }
        try Data(data.bytes).write(to: URL(fileURLWithPath: outputPath))
        print(colored("Screenshot saved: \(outputPath)", .green))
    } catch {
        print(colored("Screenshot failed: \(error)", .red))
    }
}

private func handleAndroidScreenshot(driver: AndroidDriver, arguments: [String: String]) async {
    do {
        let data = try await driver.takeScreenshot(format: .png)
        let outputPath: String
        if let path = arguments["output"] {
            outputPath = path
        } else {
            let timestamp = Int(Date().timeIntervalSince1970)
            outputPath = FileManager.default.currentDirectoryPath + "/screenshot_\(timestamp).png"
        }
        try Data(data.bytes).write(to: URL(fileURLWithPath: outputPath))
        print(colored("Screenshot saved: \(outputPath)", .green))
    } catch {
        print(colored("Screenshot failed: \(error)", .red))
    }
}

// MARK: - Shell-like argument splitting

/// Splits a REPL line into the tool name and arguments, respecting quoted strings.
/// e.g. `tap_element "Sign In"` → ("tap_element", ["Sign In"])
/// e.g. `tap x=10 y=20` → ("tap", ["x=10", "y=20"])
private func shellSplit(_ line: String) -> (toolName: String?, parts: [String]) {
    var parts: [String] = []
    var current = ""
    var inQuote: Character?

    for char in line {
        if let q = inQuote {
            if char == q {
                inQuote = nil
            } else {
                current.append(char)
            }
        } else if char == "\"" || char == "'" {
            inQuote = char
        } else if char.isWhitespace {
            if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        } else {
            current.append(char)
        }
    }
    if !current.isEmpty {
        parts.append(current)
    }

    guard let toolName = parts.first else { return (nil, []) }
    return (toolName, Array(parts.dropFirst()))
}

// MARK: - Fuzzy suggestion

/// Returns the closest tool name to `input` using edit distance, or nil if nothing is close enough.
private func closestTool(to input: String, among candidates: [String]) -> String? {
    let threshold = max(2, input.count / 3)
    let best = candidates.min { editDistance($0, input) < editDistance($1, input) }
    guard let best, editDistance(best, input) <= threshold else { return nil }
    return best
}

private func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var dp = Array(0 ... b.count)
    for i in 1 ... a.count {
        var prev = dp[0]
        dp[0] = i
        for j in 1 ... b.count {
            let temp = dp[j]
            dp[j] = a[i - 1] == b[j - 1] ? prev : min(prev, min(dp[j], dp[j - 1])) + 1
            prev = temp
        }
    }
    return dp[b.count]
}

#if DEBUG
func test_shellSplit(_ line: String) -> (toolName: String?, parts: [String]) {
    shellSplit(line)
}

func test_closestTool(to input: String, among candidates: [String]) -> String? {
    closestTool(to: input, among: candidates)
}

func test_replBannerStyle(environment: [String: String]) -> String {
    replBannerStyle(environment: environment).topLeft
}

func test_handleBuiltin(_ line: String, toolDefinitions: [ToolDefinition]) async -> String {
    switch await handleBuiltin(line, toolDefinitions: toolDefinitions) {
    case .handled:
        return "handled"
    case .quit:
        return "quit"
    case .notHandled:
        return "notHandled"
    }
}
#endif
