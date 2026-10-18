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

    static func contextSnapshot(
        _ arguments: [String: String], discoverProfile: Bool = true, platform: Platform? = nil
    ) throws -> String? {
        let json: String
        if let inline = arguments["context_json"], !inline.isEmpty {
            json = inline
        } else if let path = arguments["context_path"], !path.isEmpty {
            json = try encodedContext(RepositoryTestProfile
                .load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), platform: platform))
        } else if discoverProfile, let context = try RepositoryTestProfile.discover(platform: platform) {
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
