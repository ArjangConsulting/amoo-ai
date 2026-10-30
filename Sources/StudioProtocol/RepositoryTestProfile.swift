import AmooCore
import Foundation

/// Repository-owned export bindings, shared by CLI generation and MCP recording.
public enum RepositoryTestProfile {
    /// Repeat this fence with distinct `targetPlatform` values for a mixed-platform repository.
    public static let contextFence = "```amoo-context\n"

    /// Loads the profile that applies at `directory`: every `amoo.md` from `directory` up to the repository
    /// root, merged so the nearer file wins. Objects merge key by key and everything else, arrays
    /// included, is replaced by the nearer file. A file with no block for `platform` adds nothing, so a
    /// platform repository inherits the orchestrator's shared context and never another platform's.
    public static func discover(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        platform: Platform? = nil
    ) throws -> StudioTestContext? {
        var layers: [Block] = []
        var root = directory.standardizedFileURL
        while true {
            let file = root.appendingPathComponent("amoo.md")
            if FileManager.default.fileExists(atPath: file.path),
               let block = try select(blocks(in: file), platform: platform) {
                layers.append(block)
            }
            if isRepositoryBoundary(root) || root.path == "/" {
                break
            }
            root = root.deletingLastPathComponent()
        }
        guard let nearest = layers.first else { return nil }
        guard layers.count > 1 else { return nearest.context }
        let merged = layers.dropFirst().reduce(nearest.raw) { inner, outer in
            merge(outer.raw, over: inner)
        }
        return try JSONDecoder().decode(
            StudioTestContext.self, from: JSONSerialization.data(withJSONObject: merged)
        )
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
        guard let block = try select(blocks(in: file), platform: platform) else {
            throw ProfileError("No context for \(platform?.rawValue ?? "the requested platform") in \(file.path).")
        }
        return block.context
    }

    /// Validates inline and embedded contexts using the same platform contract as profile files.
    public static func validate(_ context: StudioTestContext, platform: Platform?) throws {
        if let platform, let target = context.targetPlatform, target != platform {
            throw ProfileError("Context targets \(target.rawValue), but the test targets \(platform.rawValue).")
        }
    }

    /// One `amoo-context` block: the decoded context, and the raw JSON object it came from so layers
    /// can merge on keys the file actually set rather than on decoded defaults.
    private struct Block {
        let context: StudioTestContext
        let raw: [String: Any]

        init(_ data: Data, in file: URL) throws {
            context = try JSONDecoder().decode(StudioTestContext.self, from: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProfileError("An amoo-context block in \(file.path) must be a JSON object.")
            }
            raw = object
        }
    }

    private static func blocks(in file: URL) throws -> [Block] {
        let data = try Data(contentsOf: file)
        if file.pathExtension == "json" {
            return try [Block(data, in: file)]
        }
        let text = (String(bytes: data, encoding: .utf8) ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        var remaining = text.startIndex ..< text.endIndex
        var blocks: [Block] = []
        while let start = text.range(of: contextFence, range: remaining) {
            guard let end = text.range(of: "```", range: start.upperBound ..< text.endIndex) else {
                throw ProfileError("Unclosed amoo-context fence in \(file.path).")
            }
            try blocks.append(Block(Data(text[start.upperBound ..< end.lowerBound].utf8), in: file))
            remaining = end.upperBound ..< text.endIndex
        }
        guard !blocks.isEmpty else { throw ProfileError("No amoo-context fence in \(file.path).") }
        return blocks
    }

    private static func select(_ blocks: [Block], platform: Platform?) throws -> Block? {
        // One unscoped legacy context remains valid; multiple blocks must declare distinct platforms.
        if blocks.count > 1 {
            let targets = blocks.compactMap(\.context.targetPlatform)
            guard targets.count == blocks.count, Set(targets).count == targets.count else {
                throw ProfileError("Multiple amoo-context blocks must declare distinct targetPlatform values.")
            }
            guard platform != nil
            else { throw ProfileError("Select a platform when loading a multi-platform profile.") }
        }
        return blocks.first {
            platform == nil || $0.context.targetPlatform == nil || $0.context.targetPlatform == platform
        }
    }

    private static func merge(_ outer: [String: Any], over inner: [String: Any]) -> [String: Any] {
        outer.merging(inner) { outerValue, innerValue in
            guard let outerObject = outerValue as? [String: Any], let innerObject = innerValue as? [String: Any]
            else { return innerValue }
            return merge(outerObject, over: innerObject)
        }
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
