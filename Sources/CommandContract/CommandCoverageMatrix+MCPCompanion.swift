import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    static let mcpCommands: [CommandCoverage] = mcpBaseCommands + mcpCompanionCommands + mcpWebViewCommands + [
        .init(
            name: "run_steps",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "ordered steps stop at the first failure and record only executed steps"
        )
    ]

    /// Companion-lifecycle MCP tools (`amoo mcp serve` only). Split from `+MCP.swift` to keep that
    /// file under the length limit.
    static let mcpCompanionCommands: [CommandCoverage] = [
        .init(
            name: "press_key",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .textInput,
            expectedAssertion: "a hardware key press, with modifiers, reaches the frontmost app"
        ),
        .init(
            name: "set_orientation",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "device reports the requested orientation and the screen's width and height swap"
        ),
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
