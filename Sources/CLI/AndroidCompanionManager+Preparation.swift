import AmooCore
import Foundation

extension AndroidCompanionManager {
    static let buildCoordinator = AndroidBuildCoordinator()

    /// True when `start_session` would reuse the existing APKs as is. `prepareBuild` reuses under
    /// this rule and `companion status` reports `stale` under it, so the two cannot disagree.
    func isBuildCurrent(config: AndroidCompanionConfig) -> Bool {
        let paths = apkPaths(companionDir: config.companionDir, useBundled: usesBundledAPKs(config: config))
        guard config.buildMode != .rebuild,
              FileManager.default.fileExists(atPath: paths.app),
              FileManager.default.fileExists(atPath: paths.test)
        else { return false }
        return config.buildMode == .reuse
            || paths.app.contains("/prebuilt/")
            || sourceFingerprintMatches(config: config)
    }

    /// Builds APKs independently of emulator boot; returns whether the products need reinstalling.
    @discardableResult
    func prepareBuild(config: AndroidCompanionConfig) async throws -> Bool {
        let paths = apkPaths(companionDir: config.companionDir, useBundled: usesBundledAPKs(config: config))
        let exists = FileManager.default.fileExists(atPath: paths.app)
            && FileManager.default.fileExists(atPath: paths.test)
        if config.buildMode == .reuse {
            guard exists else {
                throw AndroidCompanionError.buildFailed("No cached Android companion; use build_mode=auto once.")
            }
            await StartupProgress.report("Reusing Android companion build")
            return false
        }
        if isBuildCurrent(config: config) {
            await StartupProgress.report("Reusing Android companion build")
            return false
        }
        await StartupProgress.report("Building Android companion in parallel with emulator preparation")
        try await buildAPKs(config: config)
        await StartupProgress.report("Android companion build complete; waiting for emulator preparation")
        return true
    }
}

/// Single-flights Gradle builds per companion directory.
///
/// Every session on this host shares one companion project, so two `start_session` calls that both
/// need a build would otherwise run `gradlew` side by side in the same directory. The second caller
/// joins the build already running and reuses its output. The build runs in its own task, so one
/// caller's cancellation does not abort a build another caller is waiting on.
actor AndroidBuildCoordinator {
    private var inFlight: [String: Task<Void, any Error>] = [:]

    func build(key: String, operation: @escaping @Sendable () async throws -> Void) async throws {
        if let running = inFlight[key] {
            try await running.value
            return
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        try await task.value
    }
}
