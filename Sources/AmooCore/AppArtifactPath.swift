import Foundation

/// Up-front validation of an app artifact path (`build_path`, `device_install_app path`).
///
/// Without it a typo reaches `simctl`/`devicectl`/`adb` only after device boot and companion
/// startup, and surfaces as an opaque tool error (`lstat … No such file or directory`).
public enum AppArtifactPath {
    public struct ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Expands `~`, resolves a relative path against the current directory, and checks that the
    /// artifact exists and has a shape the platform can install. Returns the absolute path.
    public static func validated(
        _ raw: String,
        platform: Platform?,
        fileManager: FileManager = .default
    ) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError(description: "build path is empty.")
        }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
        let path = url.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ValidationError(description: missingMessage(for: url, fileManager: fileManager))
        }
        let ext = url.pathExtension.lowercased()
        switch platform {
        case .ios:
            guard (ext == "app" && isDirectory.boolValue) || (ext == "ipa" && !isDirectory.boolValue) else {
                throw ValidationError(
                    description: "\(path) is not an iOS app: expected a .app bundle directory or an .ipa file."
                )
            }
        case .android:
            guard ext == "apk", !isDirectory.boolValue else {
                throw ValidationError(description: "\(path) is not an Android app: expected an .apk file.")
            }
        case nil:
            break
        }
        return path
    }

    private static func missingMessage(for url: URL, fileManager: FileManager) -> String {
        var message = "No app artifact at \(url.path)."
        var ancestor = url.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor = ancestor.deletingLastPathComponent()
        }
        guard ancestor == url.deletingLastPathComponent() else {
            return message + " Deepest existing directory: \(ancestor.path)."
        }
        let suggestions = closestSiblings(to: url, in: ancestor, fileManager: fileManager)
        if !suggestions.isEmpty {
            message += " Did you mean: " + suggestions.map { ancestor.appending(path: $0).path }
                .joined(separator: ", ") + "?"
        }
        return message
    }

    /// Up to three entries in `directory` closest to the missing name, preferring the same
    /// extension so `MyApp.app` suggests `MyApp-Dev.app` rather than `MyApp.dSYM`.
    private static func closestSiblings(to url: URL, in directory: URL, fileManager: FileManager) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let target = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        let maxDistance = max(3, target.count / 3)
        let candidates: [(name: String, distance: Int)] = entries
            .filter { ext.isEmpty || ($0 as NSString).pathExtension.lowercased() == ext }
            .map { (name: $0, distance: editDistance($0.lowercased(), target)) }
            .filter { $0.distance <= maxDistance }
        let ranked = candidates.sorted { lhs, rhs in
            lhs.distance == rhs.distance ? lhs.name < rhs.name : lhs.distance < rhs.distance
        }
        return ranked.prefix(3).map(\.name)
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs), rhs = Array(rhs)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0 ... rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
