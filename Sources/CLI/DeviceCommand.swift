import AmooCore
import AndroidDriver
import CompanionProtocol
import IOSDriver
import MCPServer
import ProcessRunner

// MARK: - DeviceCommandOptions

struct DeviceCommandOptions {
    var platform: Platform
    var port: Int
    var deviceID: String?
    var tool: String
    var arguments: [String: String]
    /// `--lease <id>`: proves this caller owns the device's lease (`amoo env up`).
    var lease: String?
    /// `--json`: print one JSON object instead of the human-readable result.
    var json = false
}

// MARK: - Parsing

enum DeviceCommandParseError: Error, CustomStringConvertible {
    case missingTool
    case malformedArgument(String)
    case invalidPort(String)
    case unknownPlatform(String)
    case unknownFlag(String)

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
        case let .unknownFlag(flag) where flag.contains(where: \.isWhitespace):
            "Unknown flag '\(flag)'. Several flags arrived as one argument — pass each flag and "
                + "value separately (zsh does not word-split an unquoted $VAR; use ${=VAR} or an array)."
        case let .unknownFlag(flag):
            "Unknown flag '\(flag)'. Expected --platform, --port, --device, --lease or --json before the tool name."
        }
    }
}

private let deviceHelpUsageAndTools = """
Usage: amoo device [--platform ios|android] [--port <port>] [--device <id>] [--lease <id>] [--json]
                   <tool> [key=value ...] [--env KEY=VALUE ...] [--arg VALUE ...]

  --lease <id>   Lease from `amoo env up` (or AMOO_LEASE). Devices leased by another
                 session are refused.
  --json         Print {"tool","ok","content","structured"} as one JSON object.

Common tools:
  run_steps session_id=<id> steps=<JSON-array>
  tap x=<n> y=<n> [unit=<points|pixels|normalized>]
  double_tap x=<n> y=<n> [unit=<points|pixels|normalized>]
  long_press x=<n> y=<n> [duration_ms=<n>]
  swipe from_x=<n> from_y=<n> to_x=<n> to_y=<n> [duration_ms=<n>]
  swipe_in_direction direction=<up|down|left|right> [distance=<n>] [duration_ms=<n>]
      [element_id=<id>] [element_label=<label>]
  scroll direction=<up|down|left|right> [distance=<n>]
  type_text text=<text> [record_value=<fixture>]
  clear_text [character_count=<n>]
  set_text [id=<id>] [label=<label>] [contains_text=<text>] value=<text>
      [parent_id=<id>] [record_value=<fixture>]
      [scope=<app|system>] [bundle_id=<id>]
  fill_field [id=<id>] [label=<label>] [contains_text=<text>] [field_description=<text>]
      value=<text> [parent_id=<id>] [record_value=<fixture>]
  press_back
  press_home
  tap_element [id=<id>] [label=<label>] [contains_text=<text>] [scope=<app|system>]
      [bundle_id=<id>] [parent_id=<id>]
  find_elements [id=<id>] [label=<label>] [contains_text=<text>] [description=<text>]
      [labeled_only=<true|false>] [scope=<app|system>] [bundle_id=<id>]
      [parent_id=<id>] [limit=<n>] [offset=<n>]
  get_view_hierarchy [scope=<app|system>] [bundle_id=<id>] [format=<full|summary>] [max_nodes=<n>]
  get_screen_context
  is_keyboard_visible
  current_app
  set_target_app [bundle_id=<id>]
  take_screenshot [output=<path>] [format=<png|jpeg>] [scale=<0..1>] [return_image=<true|false>]
  describe_screen
  suggest_test_actions
  analyze_ai_testability
  highlight_a11y_issues
  find_element_by_description description=<text>
  webview_eval expression=<js> [bundle_id=<id>] [all_frames=<true|false>] [timeout_ms=<n>]
  webview_dom [bundle_id=<id>] [mode=<html|a11y>] [max_bytes=<n>]
  assert_visible [id=<id>] [label=<label>] [contains_text=<text>] [description=<text>]
      [timeout_ms=<n>] [parent_id=<id>]
  assert_enabled [id=<id>] [label=<label>] [contains_text=<text>] [description=<text>]
      [timeout_ms=<n>] [parent_id=<id>]
  assert_absent [id=<id>] [label=<label>] [contains_text=<text>] [description=<text>]
      [timeout_ms=<n>] [parent_id=<id>]
  assert_value [id=<id>] [label=<label>] [contains_text=<text>] [description=<text>]
      [timeout_ms=<n>] [expected=<text>] [contains=<text>] [parent_id=<id>] [record_value=<fixture>]
  assert_screen_changed from_token=<token> [timeout_ms=<n>]
  device_launch_app app_id=<id> [--env KEY=VALUE ...] [--arg VALUE ...] [timeout_ms=<n>]
      (tool-argument form: environment=<K=V,...> launch_args=<a,b,c>)
  device_terminate_app app_id=<id>
  device_install_app path=<path>
  device_uninstall_app app_id=<id>
  set_permission app_id=<id> permission=<name> [granted=<true|false>]
  set_location latitude=<n> longitude=<n>
  clear_location
  set_appearance appearance=<light|dark>
  press_key key=<left_arrow|right_arrow|up_arrow|down_arrow|return|escape|tab|space|delete|
      home|end|page_up|page_down|<char>>
      [modifiers=<command,shift,option,control>]
  set_orientation orientation=<portrait|landscape_left|landscape_right|portrait_upside_down>
  list_devices [platform=<ios|android>] [include_offline=<true|false>]
  open_url url=<url>

Coordinates:
  Gestures take points; screenshots come back in pixels (points x scale). Pass
  unit=pixels to use a position read straight off a screenshot, or unit=normalized
  for a 0..1 fraction of the screen. take_screenshot reports both sizes.

  A coordinate eyeballed off a *rendered* screenshot needs two conversions, not
  one: whatever showed you the image may have downscaled it first, so multiply
  back to the original pixel size before passing unit=pixels. A tap that lands
  outside every control still reports success, so a "successful" tap that changes
  nothing is this bug until proven otherwise. Prefer tap_element / find_elements —
  they report centres in points and skip the arithmetic entirely.

Scope:
  Queries and element taps resolve against the app under test, then fall back to
  system UI when nothing matches — so a control in a permission alert or the Sign
  in with Apple sheet is reachable by label without naming its process. Pass
  scope=system or bundle_id=<id> to target one explicitly.

  find_elements reports each match's centre in points, ready to pass to tap.

Unlabeled elements:
  find_elements with no selector lists everything on screen, including elements
  with no identifier or label — shown as [unlabeled] with their type and frame.
  That is how an icon-only control reachable by no selector (a close button drawn
  as a bare SF Symbol, anything inside a third-party paywall) is found: tap its
  reported centre. Named elements are listed first, then the unlabeled ones
  smallest-first, since a small leaf is usually the button and a large one is
  usually the backdrop. Pass labeled_only=true for named elements only.
"""

private let deviceHelpEnvironmentAndDefaults = """
Environment variables:
  Repeat --env once per variable. Values may contain commas and '='.

    amoo device device_launch_app app_id=com.example.app \\
      --env UITEST=1 --env API_HOST=http://localhost:8080

  Environment is fixed when a process starts, so a variable only reaches an app
  that is launched with it — relaunch (terminate + launch) to change one. The
  equivalent tool argument, which MCP clients send, is comma-separated:

    environment=UITEST=1,API_HOST=http://localhost:8080

Launch arguments:
  Repeat --arg once per argument, or pass launch_args=<a,b,c>.

Defaults:
  platform=ios
  ios port=22087
  android port=22088
"""

func renderDeviceHelp() -> String {
    deviceHelpUsageAndTools + "\n\n" + deviceHelpEnvironmentAndDefaults
}

private struct DeviceCommandFlags {
    var platform: Platform = .ios
    var port: Int?
    var deviceID: String?
    var lease: String?
    var json = false
}

// swiftlint:disable cyclomatic_complexity - one flat case per flag.
/// Consumes leading `--flag [value]` pairs from `remaining`, stopping at the first non-flag
/// token (the tool name).
private func parseDeviceFlags(remaining: inout [String]) -> Result<DeviceCommandFlags, DeviceCommandParseError> {
    var flags = DeviceCommandFlags()

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
            flags.platform = parsed
            remaining.removeFirst()

        case "--port":
            remaining.removeFirst()
            guard let portStr = remaining.first else {
                return .failure(.invalidPort("(missing)"))
            }
            guard let parsed = Int(portStr) else {
                return .failure(.invalidPort(portStr))
            }
            flags.port = parsed
            remaining.removeFirst()

        case "--device":
            remaining.removeFirst()
            guard let udid = remaining.first else {
                return .failure(.malformedArgument("--device (missing value)"))
            }
            flags.deviceID = udid
            remaining.removeFirst()

        case "--lease":
            remaining.removeFirst()
            guard let lease = remaining.first else {
                return .failure(.malformedArgument("--lease (missing value)"))
            }
            flags.lease = lease
            remaining.removeFirst()

        case "--json":
            remaining.removeFirst()
            flags.json = true

        default:
            // Must fail, not `break`: `break` only leaves the `switch`, so the `while` would spin
            // on the same token forever at 100% CPU.
            return .failure(.unknownFlag(first))
        }
    }

    return .success(flags)
}

// swiftlint:enable cyclomatic_complexity

/// Parses `key=value` tool arguments plus repeatable `--env KEY=VALUE` / `--arg VALUE` flags
/// from the tokens following the tool name.
private func parseDeviceToolArguments(_ remaining: [String]) -> Result<[String: String], DeviceCommandParseError> {
    var arguments: [String: String] = [:]
    var envPairs: [String] = []
    var launchArgs: [String] = []

    var index = remaining.startIndex
    while index < remaining.endIndex {
        let arg = remaining[index]

        // `--env KEY=VALUE`, repeatable. Spelling environment variables as a tool argument means
        // writing `environment=KEY=VALUE`, whose two `=` read as a typo, and stacking several of
        // them into one comma-separated value makes it worse. Repeating a flag says what it means
        // and lets a value contain a comma.
        if arg == "--env" || arg == "--arg" {
            let valueIndex = remaining.index(after: index)
            guard valueIndex < remaining.endIndex else {
                return .failure(.malformedArgument("\(arg) (missing value)"))
            }
            let value = remaining[valueIndex]
            if arg == "--env" {
                guard value.contains("=") else {
                    return .failure(.malformedArgument("--env \(value) (expected KEY=VALUE)"))
                }
                envPairs.append(value)
            } else {
                launchArgs.append(value)
            }
            index = remaining.index(after: valueIndex)
            continue
        }

        let parts = arg.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else {
            return .failure(.malformedArgument(arg))
        }
        arguments[String(parts[0])] = String(parts[1])
        index = remaining.index(after: index)
    }

    // Newline-joined rather than comma-joined so a value may contain a comma; the parser accepts
    // either separator, keeping the comma form MCP clients already send. The trailing newline is
    // load-bearing: it marks the string as newline-separated even when there is a single pair,
    // which is otherwise indistinguishable from a comma-separated one and would see a lone value
    // like `LOCALES=en,fr,de` split back apart.
    if !envPairs.isEmpty {
        arguments["environment"] = envPairs.joined(separator: "\n") + "\n"
    }
    if !launchArgs.isEmpty {
        arguments["launch_args"] = launchArgs.joined(separator: ",")
    }

    return .success(arguments)
}

func parseDeviceCommandOptions(args: [String]) -> Result<DeviceCommandOptions, DeviceCommandParseError> {
    var remaining = args

    let flags: DeviceCommandFlags
    switch parseDeviceFlags(remaining: &remaining) {
    case let .success(parsed): flags = parsed
    case let .failure(error): return .failure(error)
    }

    guard let tool = remaining.first else {
        return .failure(.missingTool)
    }
    remaining.removeFirst()

    let arguments: [String: String]
    switch parseDeviceToolArguments(remaining) {
    case let .success(parsed): arguments = parsed
    case let .failure(error): return .failure(error)
    }

    return .success(DeviceCommandOptions(
        platform: flags.platform,
        port: flags.port ?? defaultPort(for: flags.platform),
        deviceID: normalizedDeviceID(flags.deviceID, for: flags.platform),
        tool: tool,
        arguments: arguments,
        lease: flags.lease,
        json: flags.json
    ))
}

// MARK: - Execution

func runDeviceCommand(
    options: DeviceCommandOptions,
    resolveCompanionDevice: @Sendable (Int) async -> String? = { port in
        await companionSimulatorUDID(port: port, processRunner: SystemProcessRunner())
    }
) async -> CLIResult {
    if let early = await devicePreflight(options) {
        return early
    }

    var options = options
    if options.platform == .ios {
        let requested = options.deviceID ?? "booted"
        let owner = await resolveCompanionDevice(options.port)
        switch CompanionOwnership(requested: requested, owner: owner) {
        case let .otherDevice(owner):
            return CLIResult(
                output: companionMismatchMessage(port: options.port, requested: requested, owner: owner),
                exitCode: 1
            )
        case .matches, .unknown:
            // `booted` is whichever simulator simctl picks, which need not be the one this
            // companion drives when several are booted. Follow the companion, so an install or
            // launch lands on the same device the queries and gestures reach.
            if requested == "booted", let owner {
                options.deviceID = owner
            }
        }
    }

    let connection = CompanionConnection(host: "127.0.0.1", port: options.port)

    let companion: GRPCCompanionClient
    do {
        companion = try GRPCCompanionClient.makeLive(connection: connection)
    } catch {
        return CLIResult(output: "Failed to connect to companion on port \(options.port): \(error)", exitCode: 1)
    }

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
    let executor = DriverToolExecutor(
        driver: driver,
        foreignBuildDetector: ForeignBuildDetector(),
        webInspector: makeWebInspecting(processRunner: SystemProcessRunner()),
        defaultPlatform: options.platform
    )

    // The WebView tools need to know which platform's debug bridge to use; `--platform` is a
    // device flag, not a tool argument, so surface it as one for them.
    var toolArguments = options.arguments
    if options.tool.hasPrefix("webview_") {
        toolArguments["platform"] = options.platform.rawValue
    }

    let result = await withCLILoadingIndicator("Running \(options.tool)") {
        await executor.execute(toolName: options.tool, arguments: toolArguments)
    }
    await companion.shutdown()

    return deviceCommandResult(
        options: options,
        content: result.isError ? annotatedDeviceError(result.content, options: options) : result.content,
        isError: result.isError,
        structured: result.structuredContent
    )
}

/// Rejects argument keys the tool does not declare, naming the ones it does.
///
/// Tools read the keys they know and ignore the rest, so a misspelt or guessed key — `query=`
/// for `find_elements` — ran the call unfiltered and returned every element on screen, which
/// reads like a real answer. `nil` when the call is fine or amoo has no schema for the tool (the
/// executor reports unknown tools itself).
func unknownArgumentMessage(tool: String, arguments: [String: String]) -> String? {
    guard let definition = MCPServer().toolDefinitions().first(where: { $0.name == tool }) else {
        return nil
    }
    let unknown = Set(arguments.keys).subtracting(definition.properties.keys).sorted()
    guard !unknown.isEmpty else { return nil }
    let accepted = definition.properties.keys.filter { $0 != "session_id" }.sorted()
    let noun = unknown.count == 1 ? "argument" : "arguments"
    return "Unknown \(noun) for \(tool): \(unknown.joined(separator: ", ")). "
        + (accepted.isEmpty ? "It takes no arguments." : "Accepted: \(accepted.joined(separator: ", ")).")
}

/// Turns a bare transport failure into something actionable.
///
/// `amoo device` does not start the companion, so the common first-run experience was a raw
/// gRPC `unavailable: … Connection refused (errno: 61)` with nothing naming the command that
/// fixes it.
private func annotatedDeviceError(_ message: String, options: DeviceCommandOptions) -> String {
    let looksLikeNoCompanion = message.contains("Connection refused")
        || message.contains("unavailable")
        || message.contains("transient failure")
    guard looksLikeNoCompanion else { return message }

    let platform = options.platform == .android ? "android" : "ios"
    return message + """


    No companion is listening on port \(options.port). Start one with:
      amoo companion start --platform \(platform)\(options.deviceID.map { " --device \($0)" } ?? "") --app <bundle-id>
    """
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
