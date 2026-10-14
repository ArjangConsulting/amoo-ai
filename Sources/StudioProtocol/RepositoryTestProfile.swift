import AmooCore
import Foundation

/// A repository integration profile lives in Markdown; its fenced context is consumed in memory.
public enum RepositoryTestProfile {
    /// Markdown fence identifying the machine-readable bindings within the reviewed profile.
    public static let contextFence = "```amoo-context\n"

    /// Loads the nearest profile walking toward the filesystem root. Malformed profiles fail loudly.
    public static func discover(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        platform: Platform? = nil
    ) throws -> StudioTestContext? {
        var root = directory.standardizedFileURL
        while true {
            let file = root.appendingPathComponent("amoo.md")
            if FileManager.default.fileExists(atPath: file.path) {
                let context = try load(file)
                if let platform, let target = context.targetPlatform, target != platform {
                    return nil
                }
                return context
            }
            let parent = root.deletingLastPathComponent()
            if parent == root {
                return nil
            }
            root = parent
        }
    }

    /// Reads either a Markdown integration profile or an explicit legacy JSON context.
    public static func load(_ file: URL) throws -> StudioTestContext {
        let data = try Data(contentsOf: file)
        if file.pathExtension == "json" {
            return try JSONDecoder().decode(StudioTestContext.self, from: data)
        }
        let text = String(bytes: data, encoding: .utf8) ?? ""
        guard let start = text.range(of: contextFence),
              let end = text.range(of: "```", range: start.upperBound ..< text.endIndex)
        else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(
            StudioTestContext.self,
            from: Data(text[start.upperBound ..< end.lowerBound].utf8)
        )
    }
}
