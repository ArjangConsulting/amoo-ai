import AmooCore
@testable import CLI
import Foundation
import TestCommons
import XCTest

final class AgentStatusTests: XCTestCase {
    private var pluginRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("plugins/amoo")
    }

    private func options(at root: URL) -> AgentInstallOptions {
        var options = AgentInstallOptions(target: root.path)
        options.clients = [.claude]
        options.scopeGiven = true
        options.executablePath = "/old/bin/amoo"
        return options
    }

    func testEveryFileStateAndBinaryPathDrift() throws {
        let root = try makeScratchDirectory().url
        var options = options(at: root)
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        XCTAssertTrue(probeAgentStatus(options, assetsRoot: pluginRoot).current)
        let plan = try agentInstallPlan(options, assetsRoot: pluginRoot)
        let missing = try XCTUnwrap(plan.first { $0.destination.lastPathComponent == "device-verifier.md" })
        let edited = try XCTUnwrap(plan.first { $0.destination.lastPathComponent == "SKILL.md" })
        try FileManager.default.removeItem(at: missing.destination)
        try Data("my edits".utf8).write(to: edited.destination)
        options.executablePath = "/new/bin/amoo"
        let status = probeAgentStatus(options, assetsRoot: pluginRoot)
        XCTAssertEqual(status.files.first { $0.path == missing.destination.path }?.state, .missing)
        XCTAssertEqual(status.files.first { $0.path == edited.destination.path }?.state, .edited)
        XCTAssertEqual(status.files.first { $0.path.hasSuffix("/agents/amoo.md") }?.state, .outdated)
        XCTAssertTrue(status.files.contains { $0.state == .current })
        XCTAssertFalse(status.current)
        try FileManager.default.removeItem(at: AgentInstallStamp.url(in: root))
        let legacy = probeAgentStatus(options, assetsRoot: pluginRoot)
        XCTAssertEqual(legacy.clients, [.claude])
        XCTAssertEqual(legacy.files.first { $0.path == edited.destination.path }?.state, .unrecorded)
        XCTAssertEqual(legacy.files.first { $0.path == missing.destination.path }?.state, .missing)
    }

    func testUpdateRewritesOutdatedAndMissingButPreservesEditsAndTheirStamp() throws {
        let root = try makeScratchDirectory().url
        var options = options(at: root)
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let missing = root.appendingPathComponent(".claude/agents/device-verifier.md")
        let edited = root.appendingPathComponent(".claude/skills/driving-amoo/SKILL.md")
        try FileManager.default.removeItem(at: missing)
        try Data("my edits".utf8).write(to: edited)
        options.executablePath = "/new/bin/amoo"
        let result = runAgentUpdate(options, assetsRoot: pluginRoot)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("skipped (edited; use --force)"))
        XCTAssertEqual(try Data(contentsOf: edited), Data("my edits".utf8))
        let status = probeAgentStatus(options, assetsRoot: pluginRoot)
        XCTAssertEqual(status.files.first { $0.path == missing.path }?.state, .current)
        XCTAssertEqual(status.files.first { $0.path.hasSuffix("/agents/amoo.md") }?.state, .current)
        XCTAssertEqual(status.files.first { $0.path == edited.path }?.state, .edited)
        options.force = true
        XCTAssertEqual(runAgentUpdate(options, assetsRoot: pluginRoot).exitCode, 0)
        XCTAssertTrue(probeAgentStatus(options, assetsRoot: pluginRoot).current)
    }

    func testLegacyUpdateRequiresForceOrOneTerminalConfirmation() throws {
        let root = try makeScratchDirectory().url
        var options = options(at: root)
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let edited = root.appendingPathComponent(".claude/agents/amoo.md")
        try Data("legacy".utf8).write(to: edited)
        try FileManager.default.removeItem(at: AgentInstallStamp.url(in: root))
        options.dryRun = true
        XCTAssertEqual(runAgentUpdate(options, assetsRoot: pluginRoot).exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AgentInstallStamp.url(in: root).path))
        options.dryRun = false
        let kept = runAgentUpdate(options, assetsRoot: pluginRoot)
        XCTAssertEqual(kept.exitCode, 0)
        XCTAssertTrue(kept.output.contains("skipped (unrecorded; use --force)"))
        XCTAssertEqual(try Data(contentsOf: edited), Data("legacy".utf8))
        let prompter = ScriptedPrompter()
        prompter.confirms = [true]
        let result = runAgentUpdateCommand(
            ["--target", root.path], prompter: prompter, interactive: { true }, assetsRoot: pluginRoot
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(prompter.transcript.count, 1)
        XCTAssertTrue(prompter.transcript[0].contains("no install record"))
        XCTAssertNotEqual(try Data(contentsOf: edited), Data("legacy".utf8))
    }

    func testStatusExitCodeJSONAndReadOnlyInspection() throws {
        let root = try makeScratchDirectory().url
        var options = options(at: root)
        options.executablePath = AgentInstallOptions().executablePath
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let args = ["--target", root.path, "--json"]
        XCTAssertEqual(runAgentStatusCommand(args, assetsRoot: pluginRoot).exitCode, 0)
        let stamp = try Data(contentsOf: AgentInstallStamp.url(in: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".claude/agents/amoo.md"))
        let result = runAgentStatusCommand(args, assetsRoot: pluginRoot)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("missing"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(result.output.utf8)))
        XCTAssertEqual(try Data(contentsOf: AgentInstallStamp.url(in: root)), stamp)
    }

    func testSharedSkillsAndBothScopesAreDeduplicatedAndDryRunDoesNotWrite() throws {
        let root = try makeScratchDirectory().url
        var options = options(at: root)
        options.clients = [.codex, .cursor]
        options.homeDirectory = root.appendingPathComponent("home").path
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let stamp = try Data(contentsOf: AgentInstallStamp.url(in: root))
        options.executablePath = "/new/bin/amoo"
        options.dryRun = true
        XCTAssertEqual(runAgentUpdate(options, assetsRoot: pluginRoot).exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: AgentInstallStamp.url(in: root)), stamp)
        let status = probeAgentStatus(options, assetsRoot: pluginRoot)
        XCTAssertEqual(Set(status.files.map(\.path)).count, status.files.count)
        options.scopeGiven = false
        XCTAssertEqual(agentStatusScopes(options).map(\.scope), [.project, .user])
        options.homeDirectory = root.path
        XCTAssertEqual(agentStatusScopes(options).count, 1)
    }

    func testBundledSourceChangeIsOutdatedAndUpdateRefreshesItsHash() throws {
        let root = try makeScratchDirectory().url
        let assets = root.appendingPathComponent("plugin")
        try FileManager.default.copyItem(at: pluginRoot, to: assets)
        let options = options(at: root.appendingPathComponent("repo"))
        XCTAssertEqual(runAgentInstall(options, assetsRoot: assets).exitCode, 0)
        let source = assets.appendingPathComponent("agents/amoo.md")
        let changed = try String(contentsOf: source, encoding: .utf8) + "\nUpdated bundled instructions.\n"
        try changed.write(to: source, atomically: true, encoding: .utf8)
        let status = probeAgentStatus(options, assetsRoot: assets)
        XCTAssertEqual(status.files.first { $0.path.hasSuffix("/agents/amoo.md") }?.state, .outdated)
        XCTAssertEqual(runAgentUpdate(options, assetsRoot: assets).exitCode, 0)
        XCTAssertTrue(probeAgentStatus(options, assetsRoot: assets).current)
    }

    func testMalformedStampRefusesUpdateAndClientFilterDoesNotInventAnInstall() throws {
        let root = try makeScratchDirectory().url
        var options = options(at: root)
        options.clientsGiven = true
        XCTAssertFalse(probeAgentStatus(options, assetsRoot: pluginRoot).found)
        try Data("invalid".utf8).write(to: AgentInstallStamp.url(in: root))
        let status = probeAgentStatus(options, assetsRoot: pluginRoot)
        XCTAssertNotNil(status.error)
        XCTAssertEqual(runAgentUpdate(options, assetsRoot: pluginRoot).exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude").path))
    }

    func testUnreadableStampBlocksInstallWithAHintAndForceRewritesIt() throws {
        let root = try makeScratchDirectory().url
        var options = options(at: root)
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        try Data("<<<<<<< HEAD".utf8).write(to: AgentInstallStamp.url(in: root))
        let blocked = runAgentInstall(options, assetsRoot: pluginRoot)
        XCTAssertEqual(blocked.exitCode, 1)
        XCTAssertTrue(blocked.output.contains("is unreadable"))
        XCTAssertTrue(blocked.output.contains("--force"))
        let status = probeAgentStatus(options, assetsRoot: pluginRoot)
        XCTAssertTrue(status.found)
        XCTAssertNotNil(status.error)
        options.force = true
        XCTAssertEqual(runAgentUpdate(options, assetsRoot: pluginRoot).exitCode, 0)
        XCTAssertNotNil(try AgentInstallStamp.read(in: root))
        XCTAssertTrue(probeAgentStatus(options, assetsRoot: pluginRoot).current)
    }

    func testNewerStampSchemaIsReportedAsUnreadable() throws {
        let root = try makeScratchDirectory().url
        let options = options(at: root)
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let url = AgentInstallStamp.url(in: root)
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"schema\" : 1", with: "\"schema\" : 2")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(runAgentInstall(options, assetsRoot: pluginRoot).output.contains("unsupported schema 2"))
    }

    func testStatusAndUpdateKeepTheRecordedBinaryForTheSameRelease() throws {
        let root = try makeScratchDirectory().url
        let recorded = root.appendingPathComponent("homebrew-amoo")
        try Data("#!/bin/sh\n".utf8).write(to: recorded)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorded.path)
        var options = options(at: root)
        options.executablePath = recorded.path
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        options.executablePath = "/debug/bin/amoo"
        let status = probeAgentStatus(options, assetsRoot: pluginRoot)
        XCTAssertTrue(status.current)
        XCTAssertEqual(status.binary, recorded.path)
        let dryRun = runAgentUpdate(options, assetsRoot: pluginRoot)
        XCTAssertEqual(dryRun.exitCode, 0)
        XCTAssertFalse(dryRun.output.contains("updated"))
        XCTAssertEqual(try AgentInstallStamp.read(in: root)?.binary, recorded.path)
        options.binaryGiven = true
        XCTAssertFalse(probeAgentStatus(options, assetsRoot: pluginRoot).current)
        try FileManager.default.removeItem(at: recorded)
        options.binaryGiven = false
        XCTAssertEqual(probeAgentStatus(options, assetsRoot: pluginRoot).binary, "/debug/bin/amoo")
        XCTAssertTrue(runAgentUpdate(options, assetsRoot: pluginRoot).output.contains("updated"))
        XCTAssertEqual(try AgentInstallStamp.read(in: root)?.binary, "/debug/bin/amoo")
    }

    func testAgentFlagNarrowsStatusAndUpdate() throws {
        let root = try makeScratchDirectory().url
        let options = options(at: root)
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let full = probeAgentStatus(options, assetsRoot: pluginRoot)
        let args = ["--target", root.path, "--client", "claude", "--agent", "amoo", "--json"]
        let parsed = try parseAgentInstallOptions(args)
        let narrowed = probeAgentStatus(parsed, assetsRoot: pluginRoot)
        XCTAssertEqual(narrowed.agents, ["amoo"])
        XCTAssertLessThan(narrowed.files.count, full.files.count)
        XCTAssertFalse(narrowed.files.contains { $0.path.hasSuffix("device-verifier.md") })
    }
}
