@testable import CLI
import Foundation
import XCTest

/// A project whose Claude `amoo` agent would shadow the user's own deleted it after every sync,
/// because narrowing with `--agent` also dropped it for every other client. `--skip claude:amoo` is
/// recorded and leaves out only that client's agent file.
final class AgentSkipTests: XCTestCase {
    private var pluginRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("plugins/amoo")
    }

    func testSkippedAgentStaysOutAcrossUpdatesForThatClientOnly() throws {
        let root = try makeScratchDirectory().url
        var options = AgentInstallOptions(target: root.path)
        options.clients = [.claude, .codex]
        options.scopeGiven = true
        options.executablePath = "/old/bin/amoo"
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let claudeAmoo = root.appendingPathComponent(".claude/agents/amoo.md")
        try FileManager.default.removeItem(at: claudeAmoo)

        var skip = options
        skip.clientsGiven = false
        skip.skipped = ["claude:amoo"]
        skip.skippedGiven = true
        XCTAssertEqual(runAgentUpdate(skip, assetsRoot: pluginRoot).exitCode, 0)
        XCTAssertEqual(try AgentInstallStamp.read(in: root)?.skipped, ["claude:amoo"])

        var plain = options
        plain.clientsGiven = false
        XCTAssertEqual(runAgentUpdate(plain, assetsRoot: pluginRoot).exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeAmoo.path), "a later update keeps it out")
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: root.appendingPathComponent(".codex/agents/amoo.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".claude/skills/driving-amoo/SKILL.md").path
        ), "skills stay")
        XCTAssertTrue(probeAgentStatus(plain, assetsRoot: pluginRoot).current)
    }

    func testSkipNamesAKnownClientAndAgent() {
        XCTAssertEqual(try parseAgentSkip("claude:amoo"), "claude:amoo")
        XCTAssertThrowsError(try parseAgentSkip("claude"))
        XCTAssertThrowsError(try parseAgentSkip("vim:amoo"))
        XCTAssertThrowsError(try parseAgentSkip("claude:nope"))
    }
}
