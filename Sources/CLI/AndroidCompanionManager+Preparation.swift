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
        return !isBuildStale(config: config)
    }

    /// Checks for an existing build independently of emulator boot, and compiles only for an explicit
    /// `build_mode=rebuild`. Returns whether the products need reinstalling.
    @discardableResult
    func prepareBuild(config: AndroidCompanionConfig) async throws -> Bool {
        let paths = apkPaths(companionDir: config.companionDir, useBundled: usesBundledAPKs(config: config))
        if config.buildMode == .rebuild {
            await StartupProgress.report("Rebuilding Android companion in parallel with emulator preparation")
            try await buildAPKs(config: config)
            await StartupProgress.report("Android companion build complete; waiting for emulator preparation")
            return true
        }
        guard FileManager.default.fileExists(atPath: paths.app), FileManager.default.fileExists(atPath: paths.test)
        else {
            throw AndroidCompanionError.buildFailed(Self.missingBuildMessage(config: config))
        }
        await StartupProgress.report("Reusing Android companion build")
        return false
    }

    /// `amoo companion build`: compiles the APKs from sources when no current local build exists, or
    /// always with `force`. The only route that compiles besides an explicit `build_mode=rebuild`.
    func build(config: AndroidCompanionConfig, force: Bool = false) async throws {
        let local = apkPaths(companionDir: config.companionDir, useBundled: false)
        let manager = FileManager.default
        if !force, manager.fileExists(atPath: local.app), manager.fileExists(atPath: local.test),
           sourceFingerprintMatches(config: config) {
            print("Android companion is up to date with its sources. --force rebuilds.")
            return
        }
        await StartupProgress.report("Building Android companion")
        print("Building Android companion (this may take a moment)...")
        try await buildAPKs(config: config)
        print("Android companion built.")
    }

    /// The build a start installs and what the device already holds. A different digest replaces a
    /// running companion after `amoo companion build`; unknown install state is not outdated.
    func buildIdentity(config: AndroidCompanionConfig) async -> CompanionBuildIdentity {
        let bundled = usesBundledAPKs(config: config)
        let paths = apkPaths(companionDir: config.companionDir, useBundled: bundled)
        let commitDirectory = bundled ? config.companionDir + "/prebuilt" : config.companionDir + "/app/build"
        return await CompanionBuildIdentity(
            source: bundled ? "prebuilt" : "local",
            path: paths.test,
            builtAt: CompanionBuildIdentity.timestamp(of: paths.test),
            sourceCommit: CompanionSourceCommit.read(directory: commitDirectory),
            stale: isBuildStale(config: config),
            sha256: sha256Hex(ofRegularFile: paths.test),
            installedSHA256: deviceInstallState(config: config).installed["com.amoo.companion.test"]
        )
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
