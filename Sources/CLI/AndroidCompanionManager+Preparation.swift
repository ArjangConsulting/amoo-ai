import AmooCore
import Foundation

extension AndroidCompanionManager {
    /// Builds APKs independently of emulator boot; installation waits for both to complete.
    func prepareBuild(config: AndroidCompanionConfig) async throws {
        let paths = apkPaths(companionDir: config.companionDir, useBundled: config.buildMode != .rebuild)
        let exists = FileManager.default.fileExists(atPath: paths.app)
            && FileManager.default.fileExists(atPath: paths.test)
        if config.buildMode == .reuse {
            guard exists else {
                throw AndroidCompanionError.buildFailed("No cached Android companion; use build_mode=auto once.")
            }
            await StartupProgress.report("Reusing Android companion build")
            return
        }
        let bundled = paths.app.contains("/prebuilt/")
        if config.buildMode != .rebuild, exists, bundled || sourceFingerprintMatches(config: config) {
            await StartupProgress.report("Reusing Android companion build")
            return
        }
        await StartupProgress.report("Building Android companion in parallel with emulator preparation")
        try await buildAPKs(config: config)
        await StartupProgress.report("Android companion build complete; waiting for emulator preparation")
    }
}
