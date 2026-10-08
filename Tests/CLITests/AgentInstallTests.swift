@testable import CLI
import Foundation
import TestCommons
import XCTest

final class AgentInstallTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var pluginRoot: URL {
        repoRoot.appendingPathComponent("plugins/amoo")
    }

    /// A not-yet-created path inside a scratch directory removed after the test.
    private func temporaryDirectory() throws -> URL {
        try makeScratchDirectory().url.appendingPathComponent("agent")
    }

    private func relativePaths(_ files: [AgentInstallFile], under root: URL) -> Set<String> {
        let prefix = root.standardizedFileURL.path + "/"
        return Set(files.map { $0.destination.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "") })
    }

    func testBundledPluginIsFoundFromACheckout() {
        let root = agentAssetsRoot(executableURL: nil, currentDirectoryPath: repoRoot.path)
        XCTAssertEqual(root?.standardizedFileURL, pluginRoot.standardizedFileURL)
    }

    /// Regression: `.build/release/amoo agent install` from a source build could not find the plugin.
    /// SwiftPM's `.build/release` is a symlink into `.build/<triple>/release` (or `out/Products/...`),
    /// so the checkout root is several levels above the resolved binary.
    func testBundledPluginIsFoundFromASwiftBuildBinaryThroughTheReleaseSymlink() throws {
        let checkout = try temporaryDirectory()
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent("plugins"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent("plugins/amoo"),
            withDestinationURL: pluginRoot
        )
        let products = checkout.appendingPathComponent(".build/out/Products/Release")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent(".build/release"),
            withDestinationURL: products
        )
        let executable = checkout.appendingPathComponent(".build/release/amoo")

        let root = agentAssetsRoot(executableURL: executable, currentDirectoryPath: "/")

        XCTAssertNotNil(root, "plugins/amoo must be found relative to a SwiftPM build directory")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root?.appendingPathComponent("agents/device-verifier.md").path ?? "")
        )
    }

    func testBundledPluginIsFoundInAnInstalledPrefix() throws {
        let prefix = try temporaryDirectory()
        let share = prefix.appendingPathComponent("share/amoo/plugins")
        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: pluginRoot, to: share.appendingPathComponent("amoo"))
        let executable = prefix.appendingPathComponent("bin/amoo")

        let root = agentAssetsRoot(executableURL: executable, currentDirectoryPath: "/")

        XCTAssertEqual(
            root?.standardizedFileURL.path,
            share.appendingPathComponent("amoo").standardizedFileURL.path
        )
    }

    func testProjectInstallCoversEveryClientAndSkillReferences() throws {
        let target = try temporaryDirectory()
        let files = try agentInstallPlan(AgentInstallOptions(target: target.path), assetsRoot: pluginRoot)
        let paths = relativePaths(files, under: target)

        for name in ["amoo", "device-verifier"] {
            XCTAssertTrue(paths.contains(".claude/agents/\(name).md"))
            XCTAssertTrue(paths.contains(".cursor/agents/\(name).md"))
            XCTAssertTrue(paths.contains(".codex/agents/\(name).toml"))
            XCTAssertTrue(paths.contains(".github/agents/\(name).agent.md"))
            XCTAssertTrue(paths.contains(".gemini/agents/\(name).md"))
            XCTAssertTrue(paths.contains(".opencode/agents/\(name).md"))
        }
        for skills in [".claude/skills", ".agents/skills"] {
            XCTAssertTrue(paths.contains("\(skills)/driving-amoo/SKILL.md"))
            XCTAssertTrue(paths.contains("\(skills)/driving-amoo/references/recording.md"))
            XCTAssertTrue(paths.contains("\(skills)/device-verifier/SKILL.md"))
            for platform in ["ios", "android"] {
                let directory = "\(skills)/\(platform)-accessibility"
                XCTAssertTrue(paths.contains("\(directory)/SKILL.md"))
                let reference = "\(directory)/references/platform-checks.md"
                let installed = try XCTUnwrap(files
                    .first { $0.destination.path == target.appendingPathComponent(reference).path })
                let expected = try Data(contentsOf: pluginRoot
                    .appendingPathComponent("skills/\(platform)-accessibility/references/platform-checks.md"))
                XCTAssertEqual(installed.contents, expected, "platform guidance must travel with the installed skill")
            }
        }
        XCTAssertEqual(paths.count, files.count, "every destination is written once")
    }

    func testUserInstallWritesUnderTheHomeDirectory() throws {
        let home = try temporaryDirectory()
        var options = AgentInstallOptions(target: "/nonexistent")
        options.scope = .user
        options.homeDirectory = home.path
        options.clients = [.copilot, .opencode]
        options.agents = ["amoo"]

        let paths = try relativePaths(agentInstallPlan(options, assetsRoot: pluginRoot), under: home)

        XCTAssertTrue(paths.contains(".copilot/agents/amoo.agent.md"))
        XCTAssertTrue(paths.contains(".config/opencode/agents/amoo.md"))
        XCTAssertTrue(paths.contains(".agents/skills/driving-amoo/SKILL.md"))
        XCTAssertFalse(paths.contains { $0.contains("device-verifier") })
        XCTAssertFalse(paths.contains { $0.hasPrefix(".claude") })
    }

    func testDryRunWritesNothing() throws {
        let target = try temporaryDirectory()
        var options = AgentInstallOptions(target: target.path)
        options.dryRun = true

        let result = runAgentInstall(options, assetsRoot: pluginRoot)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("would install"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testInstallsOnceAndNeverClobbersLocalEditsWithoutForce() throws {
        let target = try temporaryDirectory()
        var options = AgentInstallOptions(target: target.path)
        options.clients = [.claude]

        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let agent = target.appendingPathComponent(".claude/agents/device-verifier.md")
        XCTAssertTrue(try String(contentsOf: agent, encoding: .utf8).contains("name: device-verifier"))
        XCTAssertTrue(runAgentInstall(options, assetsRoot: pluginRoot).output.contains("unchanged"))

        try "local edit".write(to: agent, atomically: true, encoding: .utf8)
        XCTAssertTrue(runAgentInstall(options, assetsRoot: pluginRoot).output.contains("skipped"))
        XCTAssertEqual(try String(contentsOf: agent, encoding: .utf8), "local edit")

        options.force = true
        XCTAssertTrue(runAgentInstall(options, assetsRoot: pluginRoot).output.contains("updated"))
    }

    func testMissingAssetsFailClearly() {
        let result = runAgentInstall(AgentInstallOptions(target: "/tmp"), assetsRoot: nil)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Cannot find the bundled amoo plugin"))
    }

    func testParsesRepeatedAndCommaSeparatedClients() throws {
        let options = try parseAgentInstallOptions([
            "--client", "codex,gemini", "--client", "claude", "--agent", "amoo", "--user", "--dry-run"
        ])
        XCTAssertEqual(options.clients, [.codex, .gemini, .claude])
        XCTAssertEqual(options.agents, ["amoo"])
        XCTAssertEqual(options.scope, .user)
        XCTAssertTrue(options.dryRun)
        XCTAssertEqual(try parseAgentInstallOptions([]).clients, AgentClient.allCases)
    }

    func testUnknownClientIsAUsageErrorWithAgentHelp() {
        let result = handleAgentCommand(remaining: ["install", "--client", "emacs"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("unknown value 'emacs'"))
        XCTAssertTrue(result.output.contains("Usage: amoo agent install"))
        XCTAssertFalse(result.output.contains("amoo env"))
    }

    func testEmptySelectionsAndConflictingScopesAreUsageErrors() {
        for args in [
            ["--client", ""], ["--client", "claude,"], ["--agent", ","],
            ["--target", ".", "--user"]
        ] {
            XCTAssertEqual(handleAgentCommand(remaining: ["install"] + args).exitCode, 64)
        }
    }
}
