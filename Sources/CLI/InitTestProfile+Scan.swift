import Foundation
import MobileProject

/// Bounds dependency-owned Swift parsing without copying or changing its checkout.
func inspectInitHarness(
    at root: URL,
    maximumEntries: Int = 50000,
    maximumFiles: Int = 2000,
    maximumDepth: Int = 16,
    maximumTotalBytes: Int = 32_000_000
) -> UITestHarnessFacts {
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let inspector = UITestHarnessInspector()
    var index = SwiftDeclarationIndex()
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
    guard let walker = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
    ) else { return inspector.inspect(index) }
    var visited = 0
    var bytes = 0
    var files = 0
    var limited = false
    while let file = walker.nextObject() as? URL {
        visited += 1
        guard visited <= maximumEntries, files < maximumFiles, bytes < maximumTotalBytes else {
            limited = true
            break
        }
        guard let values = try? file.resourceValues(forKeys: keys) else { continue }
        let depth = file.pathComponents.count - base.pathComponents.count
        if values.isSymbolicLink == true || inspector.excludedDirectories.contains(file.lastPathComponent) {
            walker.skipDescendants()
            continue
        }
        if depth > maximumDepth {
            limited = true
            walker.skipDescendants()
            continue
        }
        guard values.isRegularFile == true, file.pathExtension == "swift",
              let size = values.fileSize, size <= inspector.maximumFileBytes else { continue }
        guard bytes + size <= maximumTotalBytes else {
            limited = true
            break
        }
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        files += 1
        bytes += size
        let path = String(file.standardizedFileURL.path.dropFirst(base.path.count + 1))
        index.add(source: source, path: path)
    }
    var facts = inspector.inspect(index)
    if limited {
        facts.diagnostics.append("Harness scan limit reached; review undiscovered sources manually.")
    }
    return facts
}
