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
    func currentSourceFingerprint(config: CompanionConfig) -> String {
        let root = URL(fileURLWithPath: config.companionDir)
        let locations = [
            root.appendingPathComponent("project.yml"),
            root.appendingPathComponent("Sources", isDirectory: true),
            root.appendingPathComponent("../../Protos", isDirectory: true).standardizedFileURL
        ]
        var hash: UInt64 = 14_695_981_039_346_656_037
        for url in sourceFiles(at: locations).sorted(by: { $0.path < $1.path }) {
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

    func sourceFingerprintMatches(config: CompanionConfig) -> Bool {
        let path = fingerprintPath(config: config)
        return (try? String(contentsOfFile: path, encoding: .utf8)) == currentSourceFingerprint(config: config)
    }

    func writeSourceFingerprint(config: CompanionConfig) throws {
        let path = fingerprintPath(config: config)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try currentSourceFingerprint(config: config).write(toFile: path, atomically: true, encoding: .utf8)
    }

    func fingerprintPath(config: CompanionConfig) -> String {
        config.companionDir + "/build/.amoo-source-fingerprint"
    }
}
