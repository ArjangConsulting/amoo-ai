import AmooCore
import AndroidDriver
import CompanionProtocol
import IOSDriver
import MCPServer
import ProcessRunner
import SwiftyTerminal

// MARK: - DeviceCommandOptions

struct DeviceCommandOptions {
    var platform: Platform
    var port: Int
    var deviceID: String?
    var tool: String
    var arguments: [String: String]
    /// `--runtime-id <id>`: proves this caller owns the device's runtime (`amoo env up`).
    var runtimeID: String?
    /// `--json`: print one JSON object instead of the human-readable result.
    var json = false
    /// `port` is the platform default, not a `--port` the caller chose, so a runtime may supply it.
    var portIsDefault = false
    /// `platform` is the iOS default, not a `--platform` the caller chose, so a runtime may supply it.
    var platformIsDefault = false
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
            "Malformed argument '\(arg)'. Expected one key=value argument."
                + " Example: amoo device find_elements 'label=Account settings'."
                + " For structured invocation use --arguments-json @arguments.json."
        case let .invalidPort(value):
            "Invalid port '\(value)'. Expected a number."
        case let .unknownPlatform(value):
            "Unknown platform '\(value)'. Expected 'ios', 'android' or 'macos'."
        case let .unknownFlag(flag) where flag.contains(where: \.isWhitespace):
            "Unknown flag '\(flag)'. Several flags arrived as one argument — pass each flag and "
                + "value separately (zsh does not word-split an unquoted $VAR; use ${=VAR} or an array)."
        case let .unknownFlag(flag):
            "Unknown flag '\(flag)'. Expected --platform, --port, --device, --runtime-id or --json "
                + "before the tool name."
        }
    }
}

private let deviceHelpUsageAndTools = """
Usage: amoo device [--platform ios|android|macos] [--port <port>] [--device <id>] [--runtime-id <id>] [--json]
                   <tool> [key=value ...] [--arguments-json <object|@path>] [--env KEY=VALUE ...] [--arg VALUE ...]

  --runtime-id <id>   Runtime from `amoo env up` (or AMOO_RUNTIME_ID). Devices controlled by another
                 session are refused.
  --json         Print {"tool","ok","content","structured"} as one JSON object.
  --arguments-json  Read a JSON argument object, preserving multiword selectors without shell splitting.
  Schema: amoo capabilities --tool <tool>

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

Live frames:
  amoo device stream [--platform ios|android] [--device <id>] [--fps <n>] streams screenshots as
  PNG files plus one JSON line per frame, without a companion or session. See
  `amoo device stream --help`.

Native video:
  amoo device --platform android --runtime-id <id> record_video output=<path.mp4> duration_seconds=5
  Records for 1–60 seconds using the device encoder. Run gestures in another CLI call using the
  same runtime while it records. Frame rate depends on the device; use this for animation evidence.

Defaults:
  platform=ios
  ios port=22087
  android port=22088
"""

func renderDeviceHelp() -> String {
    let tools = MCPServer().toolDefinitions().sorted { $0.name < $1.name }.map { definition in
        let arguments = definition.properties.keys.filter { $0 != "session_id" }.sorted().map { key in
            "[\(key)=<\(definition.properties[key]?.type ?? "string")>]"
        }.joined(separator: " ")
        return "  \(definition.name) \(arguments)"
    }.joined(separator: "\n")
    let marker = "Coordinates:"
    let parts = deviceHelpUsageAndTools.components(separatedBy: marker)
    return parts[0] + "Common tools:\n" + tools + "\n\n" + marker + parts.dropFirst().joined(separator: marker)
        + "\n\n" + deviceHelpEnvironmentAndDefaults
}

// MARK: - Execution

func runDeviceCommand(
    options requested: DeviceCommandOptions,
    resolveCompanionDevice: @Sendable (Int) async -> String? = { port in
        await companionSimulatorUDID(port: port, processRunner: SystemProcessRunner())
    }
) async -> CLIResult {
    var options: DeviceCommandOptions
    switch await prepareDeviceCommand(requested) {
    case let .ready(prepared): options = prepared
    case let .finished(early): return early
    }

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

    let access: DeviceAccessLock?
    do {
        access = try options.acquireDeviceAccess()
    } catch {
        return deviceAccessRefusal(options: options, error: error)
    }
    defer { access?.release() }

    let connection = CompanionConnection(host: "127.0.0.1", port: options.port)

    let companion: GRPCCompanionClient
    do {
        companion = try GRPCCompanionClient.makeLive(connection: connection)
    } catch {
        return CLIResult(output: "Failed to connect to companion on port \(options.port): \(error)", exitCode: 1)
    }

    let driver = await makeDeviceCommandDriver(options, companion: companion)
    if options.tool == "record_video" {
        return await runDeviceVideoCommand(options: options, driver: driver, companion: companion)
    }
    let executor = makeDeviceToolExecutor(options, driver: driver)

    // The WebView tools need to know which platform's debug bridge to use; `--platform` is a
    // device flag, not a tool argument, so surface it as one for them.
    var toolArguments = options.arguments
    if options.tool.hasPrefix("webview_") {
        toolArguments["platform"] = options.platform.rawValue
    }

    let result = await executeCarryingCredentialLaunch(executor: executor, options: options) {
        await withSpinner("Running \(options.tool)") {
            await executor.execute(toolName: options.tool, arguments: toolArguments)
        }
    }
    await companion.shutdown()

    return deviceCommandResult(
        options: options,
        content: result.isError ? annotatedDeviceError(result.content, options: options) : result.content,
        isError: result.isError,
        structured: result.structuredContent
    )
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
    // The webview tools talk to adb / webinspectord, never the companion.
    guard looksLikeNoCompanion, !options.tool.hasPrefix("webview_") else { return message }

    let platform = options.platform == .android ? "android" : "ios"
    return message + """


    No companion is listening on port \(options.port). Start one with:
      amoo companion start --platform \(platform)\(options.deviceID.map { " --device \($0)" } ?? "") --app <bundle-id>
    """
}

func defaultPort(for platform: Platform) -> Int {
    platform.defaultCompanionPort
}

func normalizedDeviceID(_ deviceID: String?, for platform: Platform) -> String? {
    switch platform {
    case .ios:
        return deviceID ?? "booted"
    case .android:
        guard let deviceID, !deviceID.isEmpty, deviceID != "booted" else { return nil }
        return deviceID
    case .macos:
        return MacHostBackend.deviceID
    }
}
