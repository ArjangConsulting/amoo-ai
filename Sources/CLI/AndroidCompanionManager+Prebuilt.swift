import AmooCore
import Foundation
import SwiftyTerminal

extension AndroidCompanionManager {
    /// Auto mode uses whichever existing APK pair is newer, the local build or packaged products;
    /// explicit reuse retains packaged selection. A start never builds, so an older pair is only warned
    /// about (see `isBuildStale`).
    func usesBundledAPKs(config: AndroidCompanionConfig) -> Bool {
        guard config.buildMode != .rebuild, hasBundledAPKs(companionDir: config.companionDir) else { return false }
        guard config.buildMode == .auto else { return true }
        let local = apkPaths(companionDir: config.companionDir, useBundled: false)
        let bundled = apkPaths(companionDir: config.companionDir, useBundled: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: local.app), manager.fileExists(atPath: local.test) else { return true }
        return max(modified(local.app), modified(local.test)) <= max(modified(bundled.app), modified(bundled.test))
    }

    /// Whether the APKs a start would install are older than their sources: a local build whose
    /// recorded fingerprint no longer matches and that predates the last source edit, or, in a source
    /// checkout, packaged APKs older than the last source edit. A release install's prebuilt ships with
    /// its sources and is never stale.
    func isBuildStale(config: AndroidCompanionConfig) -> Bool {
        guard config.buildMode == .auto else { return false }
        guard usesBundledAPKs(config: config) else {
            // `make companion-android-build` records no fingerprint; a build newer than every source
            // edit is current even without one.
            guard !sourceFingerprintMatches(config: config) else { return false }
            let local = apkPaths(companionDir: config.companionDir, useBundled: false)
            let sources = newestSourceModification(config: config) ?? .distantPast
            return sources > max(modified(local.app), modified(local.test))
        }
        guard isSourceCheckout(companionDir: config.companionDir),
              let sources = newestSourceModification(config: config) else { return false }
        let bundled = apkPaths(companionDir: config.companionDir, useBundled: true)
        return sources > max(modified(bundled.app), modified(bundled.test))
    }

    /// The one-line warning for starting a companion older than its sources.
    func staleNotice(config: AndroidCompanionConfig) -> String {
        let paths = apkPaths(companionDir: config.companionDir, useBundled: usesBundledAPKs(config: config))
        return staleCompanionNotice(
            platform: "android",
            built: max(modified(paths.app), modified(paths.test)),
            sources: newestSourceModification(config: config)
        )
    }

    /// The error for a start that found no companion build: starts never compile one.
    static func missingBuildMessage(config: AndroidCompanionConfig) -> String {
        "No built Android companion in \(config.companionDir). Starting a device never builds one; run"
            + " `amoo companion build --platform android` (or `make companion-build` in an amoo checkout),"
            + " then start again."
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

/// "The <platform> companion (built …) is older than its sources (changed …)", plus how to update it.
func staleCompanionNotice(platform: String, built: Date?, sources: Date?) -> String {
    func stamp(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown"
    }
    return "Starting the \(platform) companion built \(stamp(built)), older than its sources (changed"
        + " \(stamp(sources))). It was not rebuilt; run `amoo companion build --platform \(platform)`"
        + " (or `make companion-build`) to update it."
}

func modificationDate(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

private func modified(_ path: String) -> Date {
    modificationDate(URL(fileURLWithPath: path)) ?? .distantPast
}
