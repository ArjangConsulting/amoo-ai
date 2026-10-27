@testable import CLI
import Foundation
import TestCommons
import XCTest

// swiftlint:disable multiline_arguments

extension InitWizardTests {
    private func installedStatus(current: Bool) -> AgentStatusReport {
        AgentStatusReport(
            root: "/repo", installedVersion: "0.1.0", clients: [.claude], agents: ["amoo", "device-verifier"],
            files: [.init(path: "/repo/.claude/agents/amoo.md", state: current ? .current : .outdated)],
            installationFound: true
        )
    }

    func testCurrentInstallSkipsEveryAIClientQuestion() async throws {
        let scratch = try makeScratchDirectory()
        let prompter = ScriptedPrompter()
        let result = await runInitCommand(
            [
                "--platform",
                "ios",
                "--device",
                "phone",
                "--no-save",
                "--yes",
                "--out",
                scratch.url.appendingPathComponent("run.json").path
            ],
            runtime: runtime(
                prompter: prompter, interactive: true, discovery: discovery(devices: [candidate("phone")]),
                setup: succeedingSetup, agentStatus: { _ in self.installedStatus(current: true) }
            )
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("AI clients: already up to date"))
        XCTAssertFalse(prompter.transcript.joined().contains("AI clients"))
        XCTAssertFalse(prompter.transcript.joined().contains("Also set up"))
    }

    func testOutdatedInstallGetsOneUpdateConfirmationWithoutPicker() async throws {
        let scratch = try makeScratchDirectory()
        let prompter = ScriptedPrompter()
        var updated: [AgentInstallOptions] = []
        let result = await runInitCommand(
            [
                "--platform",
                "ios",
                "--device",
                "phone",
                "--no-save",
                "--yes",
                "--out",
                scratch.url.appendingPathComponent("run.json").path
            ],
            runtime: runtime(
                prompter: prompter, interactive: true, discovery: discovery(devices: [candidate("phone")]),
                setup: succeedingSetup, agentStatus: { _ in self.installedStatus(current: false) },
                updateAgents: { updated.append($0); return CLIResult(output: "updated", exitCode: 0) }
            )
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.clients, [.claude])
        XCTAssertTrue(prompter.transcript.contains("Update 1 files?"))
        XCTAssertFalse(prompter.transcript.joined().contains("AI clients to set up"))
        XCTAssertFalse(prompter.transcript.joined().contains("Also set up"))
    }

    func testHeadlessDriftOnlyPrintsHintAndNoSkillsDoesNotProbe() async throws {
        let scratch = try makeScratchDirectory()
        let base = [
            "--platform",
            "ios",
            "--device",
            "phone",
            "--non-interactive",
            "--out",
            scratch.url.appendingPathComponent("run.json").path
        ]
        let result = await runInitCommand(
            base,
            runtime: runtime(
                discovery: discovery(devices: [candidate("phone")]), setup: succeedingSetup,
                agentStatus: { _ in self.installedStatus(current: false) }
            )
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("run amoo agent update"))
        let skipped = await runInitCommand(
            base + ["--no-skills"],
            runtime: runtime(
                discovery: discovery(devices: [candidate("phone")]), setup: succeedingSetup,
                agentStatus: { _ in XCTFail("must not probe"); return self.installedStatus(current: false) }
            )
        )
        XCTAssertEqual(skipped.exitCode, 0, skipped.output)
        XCTAssertFalse(skipped.output.contains("run amoo agent update"))
    }

    func testJSONInitKeepsOneDocumentWithAnExistingInstall() async throws {
        let scratch = try makeScratchDirectory()
        let result = await runInitCommand(
            [
                "--platform",
                "ios",
                "--device",
                "phone",
                "--json",
                "--out",
                scratch.url.appendingPathComponent("run.json").path
            ],
            runtime: runtime(
                discovery: discovery(devices: [candidate("phone")]), setup: succeedingSetup,
                agentStatus: { _ in self.installedStatus(current: false) }
            )
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(result.output.utf8)))
    }

    func testCurrentStandaloneInstallSkipsPickerAndStaleInstallPointsToUpdate() throws {
        let scratch = try makeScratchDirectory()
        var options = AgentInstallOptions(target: scratch.url.path)
        options.clients = [.claude]
        XCTAssertEqual(runAgentInstall(options, assetsRoot: pluginRoot).exitCode, 0)
        let prompter = ScriptedPrompter()
        let result = runAgentInstallCommand(
            ["--target", scratch.url.path], prompter: prompter, interactive: { true }, assetsRoot: pluginRoot
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("already up to date"))
        XCTAssertFalse(prompter.transcript.joined().contains("AI clients to set up"))
        let agent = scratch.url.appendingPathComponent(".claude/agents/amoo.md")
        try Data("edited".utf8).write(to: agent)
        let stale = runAgentInstallCommand(
            ["--target", scratch.url.path], prompter: prompter, interactive: { true }, assetsRoot: pluginRoot
        )
        XCTAssertTrue(stale.output.contains("Run amoo agent update"))
        XCTAssertEqual(try Data(contentsOf: agent), Data("edited".utf8))
    }
}

// swiftlint:enable multiline_arguments
