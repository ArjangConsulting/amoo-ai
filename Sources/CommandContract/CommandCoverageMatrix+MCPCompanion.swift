// SwiftFormat compact wrapping conflicts with SwiftLint argument layout.
// swiftlint:disable multiline_arguments
import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    static let mcpCommands: [CommandCoverage] = mcpBaseCommands + mcpCompanionCommands + mcpWebViewCommands +
        mcpInteractionCommands + [
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
            name: "assert_talkback_speech", channel: .mcp, kind: .deterministic,
            releaseTier: .informational, platforms: [.android], fixtureScreen: .audit,
            expectedAssertion: "explicit speech expectations compare to actual synthesis input"
                + " with restoration verified"
        ),
        .init(
            name: "test_talkback", channel: .mcp, kind: .deterministic,
            releaseTier: .informational, platforms: [.android], fixtureScreen: .audit,
            expectedAssertion: "actual TalkBack focus and synthesis requests are observed with settings restored"
        ),
        .init(
            name: "assert_accessibility_journey", channel: .mcp, kind: .deterministic,
            releaseTier: .informational, platforms: [.ios], fixtureScreen: .audit,
            expectedAssertion: "authored failures retain target/transition evidence and evaluated coverage"
        ),
        .init(
            name: "audit_accessibility_native",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .audit,
            expectedAssertion: "native issues are captured without failing the companion test"
        ),
        .init(
            name: "test_voiceover",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: [.ios],
            fixtureScreen: .audit,
            expectedAssertion: "bounded speech traversal restores the original VoiceOver state"
        ),
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
            name: "session_startup_status",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "pending and completed startup stages can be polled without blocking"
        ),
        .init(
            name: "companion_status",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "a one-line companion readiness phase is reported without blocking"
        ),
        .init(
            name: "reset_companion",
            channel: .mcp,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .environment,
            expectedAssertion: "a device's companion is stopped and its port freed for the next session"
        )
    ]
}

// swiftlint:enable multiline_arguments
