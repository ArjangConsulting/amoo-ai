import Foundation

extension AndroidCompanionManager {
    func currentSourceFingerprint(config: AndroidCompanionConfig) -> String {
        let root = URL(fileURLWithPath: config.companionDir)
        let locations = [
            root.appendingPathComponent("app/src", isDirectory: true),
            root.appendingPathComponent("app/build.gradle.kts"),
            root.appendingPathComponent("build.gradle.kts"),
            root.appendingPathComponent("settings.gradle.kts")
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

    private func sourceFiles(at locations: [URL]) -> [URL] {
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

    private func fingerprint(_ hash: UInt64, byte: UInt8) -> UInt64 {
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }

    func sourceFingerprintMatches(config: AndroidCompanionConfig) -> Bool {
        (try? String(contentsOfFile: fingerprintPath(config: config), encoding: .utf8))
            == currentSourceFingerprint(config: config)
    }

    /// Records `fingerprint` (hashed before the build it describes), or the current one when omitted.
    func writeSourceFingerprint(config: AndroidCompanionConfig, fingerprint: String? = nil) throws {
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

    private func fingerprintPath(config: AndroidCompanionConfig) -> String {
        config.companionDir + "/app/build/.amoo-source-fingerprint"
    }
}
