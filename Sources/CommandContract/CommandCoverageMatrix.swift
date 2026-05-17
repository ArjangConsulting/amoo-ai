import Foundation
import MobileTestingCore

public enum CommandChannel: String, Sendable, CaseIterable {
    case mcp
    case cli
}

public enum CommandKind: String, Sendable, CaseIterable {
    case deterministic
    case ai
}

public enum ReleaseTier: String, Sendable, CaseIterable {
    case blocking
    case informational
}

public enum FixtureScreen: String, Sendable, CaseIterable {
    case environment
    case companionInstall
    case home
    case details
    case textInput
    case gesture
    case permissions
    case appearance
    case deepLink
    case confirmation
    case launcher
    case audit
}

public struct CommandCoverage: Sendable, Equatable {
    public let name: String
    public let channel: CommandChannel
    public let kind: CommandKind
    public let releaseTier: ReleaseTier
    public let platforms: Set<Platform>
    public let fixtureScreen: FixtureScreen
    public let expectedAssertion: String

    public init(
        name: String,
        channel: CommandChannel,
        kind: CommandKind,
        releaseTier: ReleaseTier,
        platforms: Set<Platform>,
        fixtureScreen: FixtureScreen,
        expectedAssertion: String
    ) {
        self.name = name
        self.channel = channel
        self.kind = kind
        self.releaseTier = releaseTier
        self.platforms = platforms
        self.fixtureScreen = fixtureScreen
        self.expectedAssertion = expectedAssertion
    }
}

// swiftlint:disable:next type_body_length
public enum CommandCoverageMatrix {
    public static let mcpCommands: [CommandCoverage] = [
        // Device lifecycle and app management
        .init(
            name: "device_boot",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "device boots or reports already booted"
        ),
        .init(
            name: "device_shutdown",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "device shuts down cleanly"
        ),
        .init(
            name: "device_install_app",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .companionInstall,
            expectedAssertion: "fixture app is installed on the device"
        ),
        .init(
            name: "device_launch_app",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "fixture home screen becomes visible"
        ),
        .init(
            name: "device_terminate_app",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .confirmation,
            expectedAssertion: "fixture app is no longer foregrounded"
        ),
        .init(
            name: "device_uninstall_app",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .confirmation,
            expectedAssertion: "fixture app is removed from the installed package list"
        ),
        .init(
            name: "set_permission",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .permissions,
            expectedAssertion: "permission command completes against the fixture app"
        ),
        .init(
            name: "set_location",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .deepLink,
            expectedAssertion: "location simulation command succeeds"
        ),
        .init(
            name: "clear_location",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .deepLink,
            expectedAssertion: "location simulation is cleared"
        ),
        .init(
            name: "set_appearance",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .appearance,
            expectedAssertion: "fixture appearance indicator changes"
        ),

        // Actions
        .init(
            name: "tap",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "coordinate tap changes selected fixture state"
        ),
        .init(
            name: "double_tap",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "double tap counter increments"
        ),
        .init(
            name: "long_press",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "long press confirmation becomes visible"
        ),
        .init(
            name: "swipe",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .gesture,
            expectedAssertion: "swipe command navigates or updates the gesture screen"
        ),
        .init(
            name: "swipe_in_direction",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .gesture,
            expectedAssertion: "directional swipe navigates or updates the gesture screen"
        ),
        .init(
            name: "scroll",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "details list reveals off-screen fixture content"
        ),
        .init(
            name: "type_text",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "fixture text field contains the typed value"
        ),
        .init(
            name: "clear_text",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "fixture text field is emptied"
        ),
        .init(
            name: "press_back",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "back navigation returns to the previous fixture screen"
        ),
        .init(
            name: "press_home",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .launcher,
            expectedAssertion: "system launcher or home screen is foregrounded"
        ),
        .init(
            name: "open_url",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .deepLink,
            expectedAssertion: "fixture app handles the deep link and shows the URL screen"
        ),
        .init(
            name: "tap_element",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "element tap opens the expected fixture destination"
        ),

        // Queries
        .init(
            name: "find_elements",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "stable fixture identifiers are discoverable"
        ),
        .init(
            name: "get_view_hierarchy",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "fixture hierarchy contains the current screen root"
        ),
        .init(
            name: "get_screen_context",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "screen context summary is non-empty"
        ),
        .init(
            name: "take_screenshot",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "screenshot bytes are returned"
        ),
        .init(
            name: "is_keyboard_visible",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "keyboard visibility reflects the focused input state"
        ),

        // Audit
        .init(
            name: "audit_app",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .audit,
            expectedAssertion: "audit report is produced for the fixture state"
        ),
        .init(
            name: "audit_accessibility",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .audit,
            expectedAssertion: "accessibility audit report is produced"
        ),
        .init(
            name: "audit_security",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .audit,
            expectedAssertion: "security audit report is produced"
        ),

        // Assistant support
        .init(
            name: "describe_screen",
            channel: .mcp,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "screen description is non-empty"
        ),
        .init(
            name: "suggest_test_actions",
            channel: .mcp,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "MCP returns relevant fixture action suggestions"
        ),
        .init(
            name: "analyze_ai_testability",
            channel: .mcp,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "MCP returns structured AI testability diagnostics and developer feedback"
        ),
        .init(
            name: "highlight_a11y_issues",
            channel: .mcp,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "MCP returns annotated screenshot PNG with colored overlays on elements that have accessibility issues"
        ),
        .init(
            name: "find_element_by_description",
            channel: .mcp,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "MCP resolves a natural-language description to fixture elements"
        ),

        // Session management
        .init(
            name: "start_session",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "session is created and fixture app launches under the new session_id"
        ),
        .init(
            name: "end_session",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .confirmation,
            expectedAssertion: "session is closed and fixture app is terminated"
        ),
        .init(
            name: "list_sessions",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "active sessions are listed"
        ),
        .init(
            name: "get_session_report",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "session report contains recorded actions"
        ),

        // Device & app inventory
        .init(
            name: "list_devices",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "available devices for the platform are enumerated"
        ),
        .init(
            name: "list_apps",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "installed apps are listed for the active device"
        ),

        // Intent-level tools
        .init(
            name: "navigate_to",
            channel: .mcp,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "MCP taps a matching element and reports the new screen context"
        ),
        .init(
            name: "fill_field",
            channel: .mcp,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "MCP sets the text of a matching field via setText"
        ),
        .init(
            name: "assert_visible",
            channel: .mcp,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "MCP polls for a matching element and returns a pass/fail result"
        )
    ]

    public static let cliCommands: [CommandCoverage] = [
        .init(
            name: "preflight",
            channel: .cli,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "platform preflight succeeds"
        ),
        .init(
            name: "companion install",
            channel: .cli,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .companionInstall,
            expectedAssertion: "companion app artifacts are installed for the target platform"
        ),
        .init(
            name: "mcp serve",
            channel: .cli,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "local MCP stdio server starts for AI clients"
        )
    ]

    public static var publicMCPToolNames: [String] {
        mcpCommands.map(\.name)
    }

    public static var releaseBlockingToolNames: [String] {
        mcpCommands
            .filter { $0.releaseTier == .blocking && $0.kind == .deterministic }
            .map(\.name)
    }

    public static var aiToolNames: [String] {
        mcpCommands
            .filter { $0.kind == .ai }
            .map(\.name)
    }

    public static func coverage(for name: String) -> CommandCoverage? {
        (mcpCommands + cliCommands).first(where: { $0.name == name })
    }

    private static let allPlatforms: Set<Platform> = [.ios, .android]
}
