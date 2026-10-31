import AmooCore
import Foundation
import SessionCompiler
import StudioProtocol
import TestSession

/// App-owned test context: loading it for a session and folding it into compiled plans.
extension DriverToolExecutor {
    /// Loads the app-owned `StudioTestContext` named by a session's codegen intent (a file path or
    /// inline JSON) into the compiled plan for the host harness, helpers, and identifier catalog.
    /// A no-op when the intent carries no context reference.
    static func applyingTestContext(
        _ intent: SessionCodegenIntent?,
        to result: CompileSessionToPlanResult
    ) throws -> CompileSessionToPlanResult {
        guard let intent else { return result }
        let context: StudioTestContext
        if let json = intent.contextJSON, !json.isEmpty {
            context = try JSONDecoder().decode(StudioTestContext.self, from: Data(json.utf8))
        } else if let path = intent.contextPath, !path.isEmpty {
            context = try RepositoryTestProfile.load(
                URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                platform: result.studioTest.platform
            )
        } else {
            return result
        }
        try RepositoryTestProfile.validate(context, platform: result.studioTest.platform)
        return CompileSessionToPlanResult(
            testFlow: result.testFlow,
            studioTest: result.studioTest.replacingTestContext(context),
            warnings: result.warnings,
            retryRunObservations: result.retryRunObservations,
            retryTapIntervalSeconds: result.retryTapIntervalSeconds
        )
    }

    /// `discoveryDirectory` is where automatic discovery starts: the server's working directory in
    /// production, so a server started at an orchestrator root finds the platform repository's profile
    /// through the root `amoo.md`'s `repo`.
    static func contextSnapshot(
        _ arguments: [String: String],
        discoverProfile: Bool = true,
        platform: Platform? = nil,
        discoveryDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) throws -> String? {
        let json: String
        if let inline = arguments["context_json"], !inline.isEmpty {
            json = inline
        } else if let path = arguments["context_path"], !path.isEmpty {
            json = try encodedContext(RepositoryTestProfile
                .load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), platform: platform))
        } else if discoverProfile,
                  let context = try RepositoryTestProfile.discover(from: discoveryDirectory, platform: platform) {
            json = try encodedContext(context)
        } else {
            return nil
        }
        let context = try JSONDecoder().decode(StudioTestContext.self, from: Data(json.utf8))
        try RepositoryTestProfile.validate(context, platform: platform)
        return json
    }

    private static func encodedContext(_ context: StudioTestContext) throws -> String {
        guard let json = try String(bytes: JSONEncoder().encode(context), encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return json
    }
}

/// The launch configuration a session starts with.
extension DriverToolExecutor {
    struct LaunchConfiguration: Equatable {
        var arguments: [String]
        var environment: [String: String]
        /// `explicit` (the caller's), `profile` (the repository's `amoo.md` / context), `explicit+profile`
        /// (explicit arguments over profile environment, or the reverse) or `none`.
        var source: String
    }

    /// Explicit `launch_args` and `environment` win. The profile supplies what the caller left out,
    /// so a recording is made under the language, locale and text size the repository's tests use
    /// without every caller having to remember them. The profile's environment sits beneath an
    /// explicit one key by key.
    static func launchConfiguration(arguments: [String: String], contextJSON: String?) -> LaunchConfiguration {
        let explicitArguments: [String] = arguments["launch_args"]
            .map { $0.split(separator: ",").map(String.init) } ?? []
        let explicitEnvironment = parseEnvironment(arguments["environment"])
        let profile = contextJSON.flatMap { try? JSONDecoder().decode(StudioTestContext.self, from: Data($0.utf8)) }
        let profileArguments = explicitArguments.isEmpty ? profile?.launchArguments ?? [] : []
        let profileEnvironment = profile?.launchEnvironment ?? [:]
        let environment = profileEnvironment.merging(explicitEnvironment) { _, explicit in explicit }
        let usedProfile = !profileArguments.isEmpty || profileEnvironment.keys
            .contains { explicitEnvironment[$0] == nil }
        let usedExplicit = !explicitArguments.isEmpty || !explicitEnvironment.isEmpty
        let source = switch (usedExplicit, usedProfile) {
        case (true, true): "explicit+profile"
        case (true, false): "explicit"
        case (false, true): "profile"
        case (false, false): "none"
        }
        return LaunchConfiguration(
            arguments: explicitArguments.isEmpty ? profileArguments : explicitArguments,
            environment: environment,
            source: source
        )
    }
}
