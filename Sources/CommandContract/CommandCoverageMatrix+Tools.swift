import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    static let toolBaseCommands: [CommandCoverage] = [
        // Device lifecycle and app management
        .init(
            name: "device_boot",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "device boots or reports already booted"
        ),
        .init(
            name: "device_shutdown",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "device shuts down cleanly"
        ),
        .init(
            name: "device_install_app",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .companionInstall,
            expectedAssertion: "fixture app is installed on the device"
        ),
        .init(
            name: "device_launch_app",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "fixture home screen becomes visible"
        ),
        .init(
            name: "device_terminate_app",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .confirmation,
            expectedAssertion: "fixture app is no longer foregrounded"
        ),
        .init(
            name: "device_pull_app_file",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "a file the fixture app wrote is copied to the host with its size"
        ),
        .init(
            name: "device_uninstall_app",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .confirmation,
            expectedAssertion: "fixture app is removed from the installed package list"
        ),
        .init(
            name: "set_permission",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .permissions,
            expectedAssertion: "permission command completes against the fixture app"
        ),
        .init(
            name: "set_location",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .deepLink,
            expectedAssertion: "location simulation command succeeds"
        ),
        .init(
            name: "clear_location",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .deepLink,
            expectedAssertion: "location simulation is cleared"
        ),
        .init(
            name: "set_appearance",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .appearance,
            expectedAssertion: "fixture appearance indicator changes"
        ),

        // Actions
        .init(
            name: "tap",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "coordinate tap changes selected fixture state"
        ),
        .init(
            name: "double_tap",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "double tap counter increments"
        ),
        .init(
            name: "long_press",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "long press confirmation becomes visible"
        ),
        .init(
            name: "swipe",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .gesture,
            expectedAssertion: "swipe command navigates or updates the gesture screen"
        ),
        .init(
            name: "swipe_in_direction",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .gesture,
            expectedAssertion: "directional swipe navigates or updates the gesture screen"
        ),
        .init(
            name: "scroll",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "details list reveals off-screen fixture content"
        ),
        .init(
            name: "type_text",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "fixture text field contains the typed value"
        ),
        .init(
            name: "clear_text",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "fixture text field is emptied"
        ),
        .init(
            name: "press_back",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "back navigation returns to the previous fixture screen"
        ),
        .init(
            name: "press_home",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .launcher,
            expectedAssertion: "system launcher or home screen is foregrounded"
        ),
        .init(
            name: "open_url",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .deepLink,
            expectedAssertion: "fixture app handles the deep link and shows the URL screen"
        ),
        .init(
            name: "tap_element",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "element tap opens the expected fixture destination"
        ),

        // Queries
        .init(
            name: "find_elements",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "stable fixture identifiers are discoverable"
        ),
        .init(
            name: "get_view_hierarchy",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "fixture hierarchy contains the current screen root"
        ),
        .init(
            name: "get_screen_context",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "screen context summary is non-empty"
        ),
        .init(
            name: "take_screenshot",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "screenshot bytes are returned"
        ),
        .init(
            name: "is_keyboard_visible",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "keyboard visibility reflects the focused input state"
        ),

        .init(
            name: "current_app",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "reports the frontmost bundle id, never the companion host app"
        ),
        .init(
            name: "set_target_app",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "binds the app under test for subsequent commands"
        ),

        // Audit
        .init(
            name: "audit_app",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .audit,
            expectedAssertion: "audit report is produced for the fixture state"
        ),
        .init(
            name: "audit_accessibility",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .audit,
            expectedAssertion: "accessibility audit report is produced"
        ),
        .init(
            name: "audit_security",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .audit,
            expectedAssertion: "security audit report is produced"
        ),

        // Assistant support
        .init(
            name: "describe_screen",
            channel: .tool,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "screen description is non-empty"
        ),
        .init(
            name: "suggest_test_actions",
            channel: .tool,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "the tool returns relevant fixture action suggestions"
        ),
        .init(
            name: "analyze_ai_testability",
            channel: .tool,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "the tool returns structured AI testability diagnostics and developer feedback"
        ),
        .init(
            name: "highlight_a11y_issues",
            channel: .tool,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "the tool returns annotated screenshot PNG with colored overlays on elements"
                + " that have accessibility issues"
        ),
        .init(
            name: "find_element_by_description",
            channel: .tool,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "the tool resolves a natural-language description to fixture elements"
        ),

        // Session management
        .init(
            name: "start_session",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "session is created and fixture app launches under the new session_id"
        ),
        .init(
            name: "end_session",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .confirmation,
            expectedAssertion: "session is closed and fixture app is terminated"
        ),
        .init(
            name: "list_sessions",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "active sessions are listed"
        ),
        .init(
            name: "get_session_report",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "session report contains recorded actions"
        ),
        .init(
            name: "compile_session_to_plan",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "session compiles into a replayable flow and a best-effort studio test plan"
        ),

        // Device & app inventory
        .init(
            name: "list_devices",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "available devices for the platform are enumerated"
        ),
        .init(
            name: "list_apps",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "installed apps are listed for the active device"
        ),
        // Intent-level tools
        .init(
            name: "navigate_to",
            channel: .tool,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "the tool taps a matching element and reports the new screen context"
        ),
        .init(
            name: "fill_field",
            channel: .tool,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "the tool sets the text of a matching field via setText"
        ),
        .init(
            name: "set_text",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "an exact field selector is filled atomically and the matched field is reported"
        ),
        .init(
            name: "assert_visible",
            channel: .tool,
            kind: .ai,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "the tool polls for a matching element and returns a pass/fail result"
        ),
        .init(
            name: "assert_enabled",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "a matching visible control is enabled"
        ),
        .init(
            name: "assert_absent",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "no element matches the selector before timeout"
        ),
        .init(
            name: "assert_value",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "the selected element exposes the expected value"
        ),
        .init(
            name: "assert_screen_changed",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "the current screen token differs from the baseline"
        )
    ]
}
