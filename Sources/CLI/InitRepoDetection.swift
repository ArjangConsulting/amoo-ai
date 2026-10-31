import AmooCore
import Foundation
import StudioProtocol

/// Directories below an orchestrator root that look like a platform's repository, for the guided
/// `--repo` question. Empty when the root is itself that platform's project, since there is nothing to
/// choose. Looks at submodule paths from `.gitmodules` and at the root's immediate children only, and
/// never at hidden or dependency directories, so the answer is cheap and stable.
func detectInitRepos(at root: URL, platform: Platform) -> [String] {
    guard !hasPlatformMarkers(root, platform: platform) else { return [] }
    var found: [String] = []
    var seen = Set<String>()
    func consider(_ relative: String) {
        guard RepositoryTestProfile.isContainedRelativePath(relative),
              seen.insert(relative.lowercased()).inserted,
              hasPlatformMarkers(root.appendingPathComponent(relative, isDirectory: true), platform: platform)
        else { return }
        found.append(relative)
    }
    for path in submodulePaths(in: root) {
        consider(path)
    }
    let children = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    for name in children.sorted() where !name.hasPrefix(".") && !ignoredInitRepoDirectories.contains(name) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            consider(name)
        }
    }
    return found
}

private let ignoredInitRepoDirectories: Set<String> = [
    "node_modules", "build", "Pods", "DerivedData", "Carthage", "vendor"
]

/// An Xcode project, workspace or XcodeGen spec marks an iOS app; a Gradle settings file marks an Android one.
private func hasPlatformMarkers(_ directory: URL, platform: Platform) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    switch platform {
    case .ios:
        return names.contains { name in
            ["xcodeproj", "xcworkspace"].contains((name as NSString).pathExtension) || name == "project.yml"
        }
    case .android:
        return names.contains { $0 == "settings.gradle" || $0 == "settings.gradle.kts" }
    }
}

private func submodulePaths(in root: URL) -> [String] {
    guard let text = try? String(contentsOf: root.appendingPathComponent(".gitmodules"), encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 && parts[0] == "path" ? parts[1] : nil
    }
}
