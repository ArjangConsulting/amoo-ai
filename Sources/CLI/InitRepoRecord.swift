import AmooCore
import Foundation
import StudioProtocol

/// Records which repository owns a platform in the orchestrator's `amoo.md`, so the CLI and the amoo
/// subagents find that repository, its `amoo.md` and its `.amoo.json` without being told.
///
/// Returns a note for the owner when the file cannot be updated safely. A reviewed block is never
/// rewritten: the owner adds `"repo"` to it.
func recordInitRepo(at root: URL, platform: Platform, repo: String) throws -> String? {
    let file = root.appendingPathComponent("amoo.md")
    let block = try renderRepoBlock(platform: platform, repo: repo)
    guard FileManager.default.fileExists(atPath: file.path) else {
        let header = "# Amoo repository integration\n\nWritten by `amoo init --repo`. "
            + "Each platform's own `amoo.md` in its repository layers over this one.\n\n"
        try (header + block).write(to: file, atomically: true, encoding: .utf8)
        return nil
    }
    let note = "Add \"repo\": \"\(repo)\" to the \(platform.rawValue) amoo-context block in amoo.md "
        + "so amoo finds the \(platform.rawValue) repository from here."
    let scopes: [Platform?]
    do { scopes = try RepositoryTestProfile.declaredPlatforms(in: file) } catch {
        return "Could not read amoo.md (\(error)). \(note)"
    }
    if scopes.contains(where: { $0 == nil }) {
        return "amoo.md has an unscoped amoo-context block, so a \(platform.rawValue) block cannot be added. "
            + note
    }
    if scopes.contains(platform) {
        let declared = try? RepositoryTestProfile.repositoryDirectory(for: platform, from: root)
        let expected = root.appendingPathComponent(repo, isDirectory: true).standardizedFileURL
        return declared == expected ? nil : note
    }
    let existing = try String(contentsOf: file, encoding: .utf8)
    let separator = existing.hasSuffix("\n") ? "\n" : "\n\n"
    try (existing + separator + block).write(to: file, atomically: true, encoding: .utf8)
    return nil
}

private func renderRepoBlock(platform: Platform, repo: String) throws -> String {
    struct Entry: Encodable {
        var repo: String
        var targetPlatform: Platform
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let json = try String(bytes: encoder.encode(Entry(repo: repo, targetPlatform: platform)), encoding: .utf8)
    else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
    return "\(RepositoryTestProfile.contextFence)\(json)\n```\n"
}
