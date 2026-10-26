// swiftlint:disable multiline_arguments
import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    /// Scrolling and keyboard helpers, plus the selected-state assertion. Split from `+MCP.swift` to keep that file
    /// under the length limit.
    static let mcpInteractionCommands: [CommandCoverage] = [
        .init(
            name: "device_health", channel: .mcp, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .home,
            expectedAssertion: "independent transport probes distinguish connectivity from app semantic readiness"
        ),
        .init(
            name: "assert_checked", channel: .mcp, kind: .deterministic, releaseTier: .informational,
            platforms: [.android], fixtureScreen: .home,
            expectedAssertion: "an existing checkable control's checked property equals expected"
        ),
        .init(
            name: "assert_state_description", channel: .mcp, kind: .deterministic, releaseTier: .informational,
            platforms: [.android], fixtureScreen: .home,
            expectedAssertion: "native state description matches independently of text/value"
        ),
        .init(
            name: "assert_selected",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "an existing element's selected state equals expected; an absent element fails"
        ),
        .init(
            name: "scroll_to_element",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "details list scrolls an off-screen fixture row into view"
        ),
        .init(
            name: "dismiss_keyboard",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "keyboard hides after dismissing it from a focused field"
        )
    ]
}

// swiftlint:enable multiline_arguments
