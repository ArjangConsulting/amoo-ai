import AmooCore
import Foundation

/// Repository-owned export bindings, shared by CLI generation and MCP recording.
public enum RepositoryTestProfile {
    /// Repeat this fence with distinct `targetPlatform` values for a mixed-platform repository.
    public static let contextFence = "```amoo-context\n"

    /// Loads the nearest profile. A profile for another platform does not leak in from a parent.
    public static func discover(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        platform: Platform? = nil
    ) throws -> StudioTestContext? {
        var root = directory.standardizedFileURL
        while true {
            let file = root.appendingPathComponent("amoo.md")
            if FileManager.default.fileExists(atPath: file.path) {
                return try select(contexts(in: file), platform: platform)
            }
            if isRepositoryBoundary(root) {
                return nil
            }
            let parent = root.deletingLastPathComponent()
            if parent == root {
                return nil
            }
            root = parent
        }
    }

    /// A repository root ends the upward search. A submodule's `.git` file keeps it going to the
    /// orchestrator; a linked worktree's `.git` file is still its own repository.
    static func isRepositoryBoundary(_ directory: URL) -> Bool {
        let git = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue {
            return true
        }
        let pointer = (try? String(contentsOf: git, encoding: .utf8)) ?? ""
        return pointer.contains("/worktrees/")
    }

    /// Reads Markdown or legacy JSON, rejecting ambiguous or wrong-platform explicit contexts.
    public static func load(_ file: URL, platform: Platform? = nil) throws -> StudioTestContext {
        guard let context = try select(contexts(in: file), platform: platform) else {
            throw ProfileError("No context for \(platform?.rawValue ?? "the requested platform") in \(file.path).")
        }
        return context
    }

    /// Validates inline and embedded contexts using the same platform contract as profile files.
    public static func validate(_ context: StudioTestContext, platform: Platform?) throws {
        if let platform, let target = context.targetPlatform, target != platform {
            throw ProfileError("Context targets \(target.rawValue), but the test targets \(platform.rawValue).")
        }
    }

    private static func contexts(in file: URL) throws -> [StudioTestContext] {
        let data = try Data(contentsOf: file)
        if file.pathExtension == "json" {
            return try [JSONDecoder().decode(StudioTestContext.self, from: data)]
        }
        let text = (String(bytes: data, encoding: .utf8) ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        var remaining = text.startIndex ..< text.endIndex
        var contexts: [StudioTestContext] = []
        while let start = text.range(of: contextFence, range: remaining) {
            guard let end = text.range(of: "```", range: start.upperBound ..< text.endIndex) else {
                throw ProfileError("Unclosed amoo-context fence in \(file.path).")
            }
            try contexts.append(JSONDecoder().decode(
                StudioTestContext.self, from: Data(text[start.upperBound ..< end.lowerBound].utf8)
            ))
            remaining = end.upperBound ..< text.endIndex
        }
        guard !contexts.isEmpty else { throw ProfileError("No amoo-context fence in \(file.path).") }
        return contexts
    }

    private static func select(_ contexts: [StudioTestContext], platform: Platform?) throws -> StudioTestContext? {
        // One unscoped legacy context remains valid; multiple blocks must declare distinct platforms.
        if contexts.count > 1 {
            let targets = contexts.compactMap(\.targetPlatform)
            guard targets.count == contexts.count, Set(targets).count == targets.count else {
                throw ProfileError("Multiple amoo-context blocks must declare distinct targetPlatform values.")
            }
            guard platform != nil
            else { throw ProfileError("Select a platform when loading a multi-platform profile.") }
        }
        return contexts.first { platform == nil || $0.targetPlatform == nil || $0.targetPlatform == platform }
    }

    private struct ProfileError: Error, LocalizedError {
        let message: String
        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? {
            message
        }
    }
}
