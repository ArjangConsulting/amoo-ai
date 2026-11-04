// swiftlint:disable multiline_arguments
import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    /// Scrolling and keyboard helpers, plus the selected-state assertion. Split from `+MCP.swift` to keep that file
    /// under the length limit.
    static let mcpInteractionCommands: [CommandCoverage] = [
        .init(
            name: "get_capabilities", channel: .mcp, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .environment,
            expectedAssertion: "installed schemas, binary identity and provider assertion support are queryable"
        ),
        .init(
            name: "get_verification_report", channel: .mcp, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .home,
            expectedAssertion: "every required check retains outcome, reason and evidence; status is derived"
        ),
        .init(
            name: "drag",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .gesture,
            expectedAssertion: "dragging the gesture lab's drag source onto its drop zone reports the drop"
        ),
        .init(
            name: "pinch",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .gesture,
            expectedAssertion: "pinching the gesture lab's zoom target out and in changes its reported scale"
        ),
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
