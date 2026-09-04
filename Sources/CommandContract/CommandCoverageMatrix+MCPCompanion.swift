import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    /// Companion-lifecycle MCP tools (`amoo mcp serve` only). Split from `+MCP.swift` to keep that
    /// file under the length limit.
    static let mcpCompanionCommands: [CommandCoverage] = [
        .init(
            name: "companion_warm",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "companion build/install starts in the background and the call returns at once"
        ),
        .init(
            name: "companion_status",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "a one-line companion readiness phase is reported without blocking"
        )
    ]
}
