import Foundation

extension AndroidCompanionManager {
    /// Auto mode prefers a newer local APK pair over packaged products; explicit reuse retains packaged selection.
    func usesBundledAPKs(config: AndroidCompanionConfig) -> Bool {
        guard config.buildMode != .rebuild, hasBundledAPKs(companionDir: config.companionDir) else { return false }
        guard config.buildMode == .auto else { return true }
        let local = apkPaths(companionDir: config.companionDir, useBundled: false)
        let bundled = apkPaths(companionDir: config.companionDir, useBundled: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: local.app), manager.fileExists(atPath: local.test) else { return true }
        func modified(_ path: String) -> Date {
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
        }
        return max(modified(local.app), modified(local.test)) <= max(modified(bundled.app), modified(bundled.test))
    }
}
