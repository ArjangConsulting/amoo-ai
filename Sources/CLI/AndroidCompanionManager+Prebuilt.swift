import AmooCore
import Foundation
import SwiftyTerminal

extension AndroidCompanionManager {
    /// Auto mode prefers a newer local APK pair over packaged products, and never uses packaged products
    /// older than the companion sources: a checkout keeps a gitignored `prebuilt/` from its last packaging
    /// run, which lacks every companion change since. Explicit reuse retains packaged selection.
    func usesBundledAPKs(config: AndroidCompanionConfig) -> Bool {
        guard config.buildMode != .rebuild, hasBundledAPKs(companionDir: config.companionDir) else { return false }
        guard config.buildMode == .auto else { return true }
        let local = apkPaths(companionDir: config.companionDir, useBundled: false)
        let bundled = apkPaths(companionDir: config.companionDir, useBundled: true)
        let bundledDate = max(modified(bundled.app), modified(bundled.test))
        if bundledAPKsSkippedReason(config: config) != nil {
            return false
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: local.app), manager.fileExists(atPath: local.test) else { return true }
        return max(modified(local.app), modified(local.test)) <= bundledDate
    }

    /// Why packaged APKs were passed over, for the startup output; nil when they were not.
    func bundledAPKsSkippedReason(config: AndroidCompanionConfig) -> String? {
        guard config.buildMode == .auto, isSourceCheckout(companionDir: config.companionDir),
              hasBundledAPKs(companionDir: config.companionDir),
              let sources = newestSourceModification(config: config) else { return nil }
        let bundled = apkPaths(companionDir: config.companionDir, useBundled: true)
        let bundledDate = max(modified(bundled.app), modified(bundled.test))
        guard sources > bundledDate else { return nil }
        return "Companion sources changed after the prebuilt companion was packaged"
            + " (\(bundledDate.formatted(date: .abbreviated, time: .shortened))); using a build from sources."
    }

    /// The line that says a packaged companion is being installed, so its age is never a surprise.
    func bundledAPKsNotice(config: AndroidCompanionConfig) -> String {
        let bundled = apkPaths(companionDir: config.companionDir, useBundled: true)
        let date = max(modified(bundled.app), modified(bundled.test))
        return "Using the prebuilt Android companion packaged \(date.formatted(date: .abbreviated, time: .shortened))"
            + " from \(config.companionDir)/prebuilt."
    }
}

/// Whether `companionDir` is `CompanionApps/<platform>` inside an amoo source checkout, which can
/// always compile its companion. A release archive ships neither `Package.swift` nor `.git`, and
/// unpacks its prebuilt companions into a fresh checkout's sources, so there the prebuilt can look
/// older than the sources while still being built from them.
func isSourceCheckout(companionDir: String) -> Bool {
    let root = URL(fileURLWithPath: companionDir).appendingPathComponent("../..").standardizedFileURL
    let manager = FileManager.default
    return manager.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
        && manager.fileExists(atPath: root.appendingPathComponent(".git").path)
}

/// Says which companion a start is about to use when that is not the obvious one, in the startup
/// progress an agent sees and on the terminal.
func announce(_ notice: String?) async {
    guard let notice else { return }
    await StartupProgress.report(notice)
    print(styled(notice, .yellow))
}

func modificationDate(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

private func modified(_ path: String) -> Date {
    modificationDate(URL(fileURLWithPath: path)) ?? .distantPast
}
