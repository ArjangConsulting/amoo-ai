import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    /// Scrolling and keyboard helpers. Split from `+MCP.swift` to keep that file under the length limit.
    static let mcpInteractionCommands: [CommandCoverage] = [
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
