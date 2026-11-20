import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import XcodeBuildKit
import XcodeGenKit

// MARK: - Source Fingerprint

/// Detects companion sources changing since the last build, so a stale runner is rebuilt rather
/// than reused.
extension CompanionManager {
    /// When a companion source file last changed, or nil when there are no sources.
    func newestSourceModification(config: CompanionConfig) -> Date? {
        sourceFiles(at: sourceLocations(config: config)).compactMap(modificationDate).max()
    }

    /// The files a companion build depends on, hashed by the fingerprint and dated by the prebuilt check.
    func sourceLocations(config: CompanionConfig) -> [URL] {
        let root = URL(fileURLWithPath: config.companionDir)
        var locations = [
            root.appendingPathComponent("project.yml"),
            root.appendingPathComponent("Recovery.entitlements"),
            root.appendingPathComponent("sign-simulator-products.py"),
            root.appendingPathComponent("HostApp", isDirectory: true),
            root.appendingPathComponent("Sources", isDirectory: true),
            root.appendingPathComponent("../../Protos", isDirectory: true).standardizedFileURL
        ] + sharedSources(root: root)
        // Only the Mac build's own host app; listing it for iOS would invalidate every iOS build once.
        if config.isMac {
            locations.append(root.appendingPathComponent("MacHostApp", isDirectory: true))
        }
        return locations
    }

    func currentSourceFingerprint(config: CompanionConfig) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for url in sourceFiles(at: sourceLocations(config: config)).sorted(by: { $0.path < $1.path }) {
            for byte in url.path.utf8 {
                hash = fingerprint(hash, byte: byte)
            }
            if let data = try? Data(contentsOf: url) {
                for byte in data {
                    hash = fingerprint(hash, byte: byte)
                }
            }
        }
        return String(hash, radix: 16)
    }

    /// The host-package files `project.yml` compiles into the companion. Hashing the whole of
    /// `Sources/AmooCore` instead made any host-only edit there cost a companion rebuild on the next
    /// start. Falls back to that directory when the manifest names none, so a change is never missed.
    func sharedSources(root: URL) -> [URL] {
        let manifest = (try? String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)) ?? ""
        let listed = manifest.split(separator: "\n").compactMap { line -> URL? in
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry.hasPrefix("- path: ../../") || entry.hasPrefix("path: ../../") else { return nil }
            let path = entry.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            return root.appendingPathComponent(path).standardizedFileURL
        }
        return listed.isEmpty
            ? [root.appendingPathComponent("../../Sources/AmooCore", isDirectory: true).standardizedFileURL]
            : listed
    }

    func sourceFiles(at locations: [URL]) -> [URL] {
        locations.flatMap { location -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else { return [] }
            if !isDirectory.boolValue {
                return [location]
            }
            guard let enumerator = FileManager.default.enumerator(
                at: location,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { item in
                guard let url = item as? URL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return nil }
                return url
            }
        }
    }

    func fingerprint(_ hash: UInt64, byte: UInt8) -> UInt64 {
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }

    /// Whether the build a start would launch is older than its sources: a local build whose recorded
    /// fingerprint no longer matches and that predates the last source edit, or, in a source checkout,
    /// prebuilt products packaged before the last source edit. A release install's prebuilt is never
    /// stale; it ships with its sources.
    ///
    /// `ensureRunning` warns under this rule and `companion status` reports `stale` under it. Neither
    /// builds: that is `amoo companion build`.
    func sourcesChanged(config: CompanionConfig, bundled: Bool) -> Bool {
        if config.buildMode == .rebuild {
            return true
        }
        guard config.buildMode != .reuse else { return false }
        guard bundled else {
            // `make companion-build` records no fingerprint, so a build newer than every source
            // edit is current even without one.
            guard !sourceFingerprintMatches(config: config) else { return false }
            let run = findXCTestRun(productsDir: config.companionDir + "/build/Build/Products", config: config)
            guard let built = run.flatMap({ modificationDate(URL(fileURLWithPath: $0)) }) else { return true }
            return (newestSourceModification(config: config) ?? .distantPast) > built
        }
        guard isSourceCheckout(companionDir: config.companionDir),
              let run = findXCTestRun(productsDir: bundledProductsDirectory(config: config), config: config),
              let packaged = modificationDate(URL(fileURLWithPath: run)),
              let sources = newestSourceModification(config: config) else { return false }
        return sources > packaged
    }

    /// The one-line warning for starting a companion older than its sources.
    func staleNotice(config: CompanionConfig, bundled: Bool) -> String {
        let products = companionProductsDirectory(config: config, bundled: bundled)
        let built = findXCTestRun(productsDir: products, config: config)
            .flatMap { modificationDate(URL(fileURLWithPath: $0)) }
        let platform = config.isMac ? "macos" : "ios"
        return staleCompanionNotice(
            platform: platform, built: built, sources: newestSourceModification(config: config)
        )
    }

    /// True when a start would launch the existing build as is: products exist and nothing that
    /// would trigger a rebuild has changed.
    func isBuildCurrent(config: CompanionConfig) -> Bool {
        let bundled = hasBundledProducts(config: config)
        let products = companionProductsDirectory(config: config, bundled: bundled)
        return findXCTestRun(productsDir: products, config: config) != nil
            && !sourcesChanged(config: config, bundled: bundled)
    }

    func sourceFingerprintMatches(config: CompanionConfig) -> Bool {
        let path = fingerprintPath(config: config)
        return (try? String(contentsOfFile: path, encoding: .utf8)) == currentSourceFingerprint(config: config)
    }

    /// Records `fingerprint` (hashed before the build it describes), or the current one when omitted.
    func writeSourceFingerprint(config: CompanionConfig, fingerprint: String? = nil) throws {
        let path = fingerprintPath(config: config)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (fingerprint ?? currentSourceFingerprint(config: config)).write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )
    }

    /// One record per build: the iOS and Mac companions share a build folder but not products, so a
    /// shared record let one platform's build mark the other's stale products as current.
    func fingerprintPath(config: CompanionConfig) -> String {
        config.companionDir + "/build/.amoo-source-fingerprint" + (config.isMac ? "-macosx" : "")
    }
}
