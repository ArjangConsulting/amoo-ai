import AndroidDriver
import CompanionProtocol
import IOSDriver
import MCPServer
import MobileTestingCore

// MARK: - DeviceCommandOptions

struct DeviceCommandOptions {
    var platform: Platform
    var port: Int
    var deviceID: String?
    var tool: String
    var arguments: [String: String]
}

// MARK: - Parsing

enum DeviceCommandParseError: Error, CustomStringConvertible {
    case missingTool
    case malformedArgument(String)
    case invalidPort(String)
    case unknownPlatform(String)

    var description: String {
        switch self {
        case .missingTool:
            renderDeviceHelp()
        case let .malformedArgument(arg):
            "Malformed argument '\(arg)'. Expected key=value format."
        case let .invalidPort(value):
            "Invalid port '\(value)'. Expected a number."
        case let .unknownPlatform(value):
            "Unknown platform '\(value)'. Expected 'ios' or 'android'."
        }
    }
}

func renderDeviceHelp() -> String {
    """
    Usage: amoo device [--platform ios|android] [--port <port>] [--device <id>] <tool> [key=value ...]

    Common tools:
      tap x=<n> y=<n>
      double_tap x=<n> y=<n>
      long_press x=<n> y=<n> [duration_ms=<n>]
      swipe from_x=<n> from_y=<n> to_x=<n> to_y=<n>
      scroll direction=<up|down|left|right> [distance=<n>]
      type_text text=<text>
      clear_text [character_count=<n>]
      press_back
      press_home
      tap_element [id=<id>] [label=<label>] [contains_text=<text>]
      find_elements [id=<id>] [label=<label>] [contains_text=<text>]
      get_view_hierarchy
      get_screen_context
      is_keyboard_visible
      take_screenshot
      describe_screen
      suggest_test_actions
      analyze_ai_testability
      find_element_by_description description=<text>
      device_launch_app app_id=<id>
      device_terminate_app app_id=<id>
      device_install_app path=<path>
      open_url url=<url>

    Defaults:
      platform=ios
      ios port=22087
      android port=22088
    """
}

// swiftlint:disable:next cyclomatic_complexity
func parseDeviceCommandOptions(args: [String]) -> Result<DeviceCommandOptions, DeviceCommandParseError> {
    var remaining = args
    var platform: Platform = .ios
    var port: Int?
    var deviceID: String?

    // Parse flags
    while let first = remaining.first, first.hasPrefix("--") {
        switch first {
        case "--platform":
            remaining.removeFirst()
            guard let platformStr = remaining.first else {
                return .failure(.malformedArgument("--platform"))
            }
            guard let parsed = Platform(rawValue: platformStr.lowercased()) else {
                return .failure(.unknownPlatform(platformStr))
            }
            platform = parsed
            remaining.removeFirst()

        case "--port":
            remaining.removeFirst()
            guard let portStr = remaining.first else {
                return .failure(.invalidPort("(missing)"))
            }
            guard let parsed = Int(portStr) else {
                return .failure(.invalidPort(portStr))
            }
            port = parsed
            remaining.removeFirst()

        case "--device":
            remaining.removeFirst()
            guard let udid = remaining.first else {
                break
            }
            deviceID = udid
            remaining.removeFirst()

        default:
            break
        }
    }

    guard let tool = remaining.first else {
        return .failure(.missingTool)
    }
    remaining.removeFirst()

    var arguments: [String: String] = [:]
    for arg in remaining {
        let parts = arg.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else {
            return .failure(.malformedArgument(arg))
        }
        arguments[String(parts[0])] = String(parts[1])
    }

    return .success(DeviceCommandOptions(
        platform: platform,
        port: port ?? defaultPort(for: platform),
        deviceID: normalizedDeviceID(deviceID, for: platform),
        tool: tool,
        arguments: arguments
    ))
}

// MARK: - Execution

func runDeviceCommand(options: DeviceCommandOptions) async -> CLIResult {
    let connection = CompanionConnection(host: "127.0.0.1", port: options.port)

    let companion: GRPCCompanionClient
    do {
        companion = try GRPCCompanionClient.makeLive(connection: connection)
    } catch {
        return CLIResult(output: "Failed to connect to companion on port \(options.port): \(error)", exitCode: 1)
    }

    let driver: any PlatformDriver = switch options.platform {
    case .ios:
        IOSDriver(companion: companion, deviceID: options.deviceID ?? "booted")
    case .android:
        AndroidDriver(companion: companion, serial: options.deviceID)
    }
    let executor = DriverToolExecutor(driver: driver)

    let result = await withCLILoadingIndicator("Running \(options.tool)") {
        await executor.execute(toolName: options.tool, arguments: options.arguments)
    }
    await companion.shutdown()

    return CLIResult(output: result.content, exitCode: result.isError ? 1 : 0)
}

private func defaultPort(for platform: Platform) -> Int {
    switch platform {
    case .ios:
        22087
    case .android:
        22088
    }
}

private func normalizedDeviceID(_ deviceID: String?, for platform: Platform) -> String? {
    switch platform {
    case .ios:
        return deviceID ?? "booted"
    case .android:
        guard let deviceID, !deviceID.isEmpty, deviceID != "booted" else { return nil }
        return deviceID
    }
}
