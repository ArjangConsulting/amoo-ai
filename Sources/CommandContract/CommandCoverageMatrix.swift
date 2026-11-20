import AmooCore
import Foundation

public enum CommandChannel: String, Sendable, CaseIterable {
    case tool
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

public enum CommandCoverageMatrix {
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
            expectedAssertion: "the removed MCP server command explains the CLI path and exits 64"
        )
    ]

    public static var publicToolNames: [String] {
        toolCommands.map(\.name)
    }

    public static var releaseBlockingToolNames: [String] {
        toolCommands
            .filter { $0.releaseTier == .blocking && $0.kind == .deterministic }
            .map(\.name)
    }

    public static var aiToolNames: [String] {
        toolCommands
            .filter { $0.kind == .ai }
            .map(\.name)
    }

    public static func coverage(for name: String) -> CommandCoverage? {
        (toolCommands + cliCommands).first(where: { $0.name == name })
    }

    static let allPlatforms: Set<Platform> = [.ios, .android]
}
