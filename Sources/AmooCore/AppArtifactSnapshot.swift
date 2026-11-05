import Foundation

/// A validated, session-owned copy of an install artifact, isolated from subsequent builds.
public struct AppArtifactSnapshot: Sendable, Codable, Equatable {
    public let path: String
    public let sourcePath: String
    public let sha256: String

    /// Copies before device startup and rejects incomplete bundles or a source that changed while copying.
    public static func create(
        source: String, platform: Platform, appID: String, directory: URL
    ) throws -> Self {
        let source = try AppArtifactPath.validated(source, platform: platform)
        let sourceURL = URL(fileURLWithPath: source)
        try validateBundle(sourceURL, appID: appID)
        let before = try fingerprint(sourceURL)
        let storage = directory.appending(path: "build", directoryHint: .isDirectory)
        let destination = storage.appending(path: sourceURL.lastPathComponent)
        try FileManager.default.createDirectory(
            at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            try validateBundle(destination, appID: appID)
            let copied = try fingerprint(destination)
            guard before == copied, try before == fingerprint(sourceURL) else {
                throw Failure("Build artifact changed during snapshot; finish the build and retry.")
            }
            return Self(path: destination.path, sourcePath: source, sha256: copied)
        } catch {
            try? FileManager.default.removeItem(at: storage)
            throw error
        }
    }

    private static func validateBundle(_ url: URL, appID: String) throws {
        guard url.pathExtension.lowercased() == "app" else {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count >= 22, data.starts(with: [0x50, 0x4B, 0x03, 0x04]),
                  data.suffix(65557).range(of: Data([0x50, 0x4B, 0x05, 0x06])) != nil else {
                throw Failure("Install artifact is not a complete ZIP archive: \(url.path)")
            }
            return
        }
        let macInfo = url.appending(path: "Contents/Info.plist")
        let isMac = FileManager.default.fileExists(atPath: macInfo.path)
        let infoURL = isMac ? macInfo : url.appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == appID,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable == (executable as NSString).lastPathComponent else {
            throw Failure("Incomplete app bundle or bundle identifier differs from \(appID): \(url.path)")
        }
        let executableURL = (isMac ? url.appending(path: "Contents/MacOS") : url).appending(path: executable)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path),
              let size = try executableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw Failure("App bundle executable is missing, empty or not executable: \(executableURL.path)")
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func fingerprint(_ root: URL) throws -> String {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        let values = try root.resourceValues(forKeys: keys)
        guard values.isDirectory == true else {
            guard let digest = sha256Hex(ofRegularFile: root.path, maximumBytes: Int.max) else {
                throw Failure("Cannot read complete install artifact: \(root.path)")
            }
            return digest
        }
        var entries: [String] = []
        var pending: [(url: URL, relative: String)] = [(root, "")]
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            for entry in try manager.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: Array(keys)) {
                let values = try entry.resourceValues(forKeys: keys)
                let relative = directory.relative.isEmpty
                    ? entry.lastPathComponent : directory.relative + "/" + entry.lastPathComponent
                entries.append(relative)
                if values.isDirectory == true, values.isSymbolicLink != true {
                    pending.append((entry, relative))
                }
            }
        }
        var digest = SHA256Digest()
        for relative in entries.sorted() {
            try Task.checkCancellation()
            let entry = root.appending(path: relative)
            let values = try entry.resourceValues(forKeys: keys)
            digest.update(Data(relative.utf8) + Data([0]))
            if values.isSymbolicLink == true {
                guard entry.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                    throw Failure("App bundle contains an external symbolic link: \(relative)")
                }
                digest.update(Data("link:".utf8))
                try digest.update(Data(manager.destinationOfSymbolicLink(atPath: entry.path).utf8))
            } else if values.isRegularFile == true {
                guard let hash = sha256Hex(ofRegularFile: entry.path, maximumBytes: Int.max) else {
                    throw Failure("Cannot read complete bundle file: \(relative)")
                }
                digest.update(Data(hash.utf8))
            } else if values.isDirectory != true {
                throw Failure("Unsupported bundle file: \(relative)")
            }
            digest.update(Data([0]))
        }
        return digest.finalizeHex()
    }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let description: String

        init(_ description: String) {
            self.description = description
        }
    }
}
