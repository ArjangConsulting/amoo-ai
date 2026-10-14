import AmooCore
@testable import CLI
import Foundation
import TestCommons
import XCTest

final class InitWizardTests: InitTestCase {
    func testBothPlatformsCollectSeparateArtifactsAndManifests() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let apk = scratch.url.appendingPathComponent("app.apk").path
        try Data("apk".utf8).write(to: URL(fileURLWithPath: apk))
        let found = InitDiscovery(
            devices: { platform in [self.candidate(platform == .ios ? "phone" : "emulator")] },
            apps: { $0 == .ios ? [app] : [apk] },
            bundleID: { _, _ in "com.jot" }
        )
        let prompter = ScriptedPrompter()
        prompter.choices = [2, 2, 0, 0] // both, Flutter, iOS artifact, Android artifact
        let completed = try await completeInitRequest(InitRequest(), discovery: found, prompter: prompter)
        let android = try XCTUnwrap(completed.additionalRequests.first)
        XCTAssertEqual(completed.platform, .ios)
        XCTAssertEqual(android.platform, .android)
        XCTAssertEqual(completed.appPath, app)
        XCTAssertEqual(android.appPath, apk)
        XCTAssertEqual(completed.devices, ["phone"])
        XCTAssertEqual(android.devices, ["emulator"])
        XCTAssertNotEqual(completed.out, android.out)
        XCTAssertTrue(prompter.transcript.joined().contains("flutter-apk"))
    }

    func testGuidedFlowAsksOnlyForWhatIsMissingAndRecordsLocations() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let agents = scratch.url.appendingPathComponent("AGENTS.md").path
        try "# Repo\n\nKeep me.\n".write(toFile: agents, atomically: true, encoding: .utf8)
        let out = scratch.url.appendingPathComponent("manifests/run.json").path
        let prompter = ScriptedPrompter()
        prompter.choices = [0, 0, 0] // platform: iOS, app: first found
        prompter.multi = [[0, 1]] // both devices
        prompter.asks = ["", "", out] // app id (detected), owner (default), manifest path
        var setups: [EnvUpOptions] = []
        let found = discovery(
            devices: [candidate("phone"), candidate("tablet"), candidate("busy", leasedBy: "x")],
            apps: [app],
            bundleID: "com.jot"
        )
        let result = await runInitCommand(
            ["--agents-file", agents, "--no-skills"],
            runtime: runtime(prompter: prompter, interactive: true, discovery: found) { options in
                setups.append(options)
                return CLIResult(
                    output: renderJSON(EnvUpReport(
                        ok: true,
                        lease: "L-\(setups.count)",
                        platform: "ios",
                        port: 22000 + setups.count
                    )),
                    exitCode: 0
                )
            }
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(setups.compactMap(\.deviceID), ["phone", "tablet"])
        XCTAssertTrue(setups
            .allSatisfy { $0.appPath == app && $0.appID == "com.jot" && $0.launch && $0.owner == "amoo-init" })
        XCTAssertEqual(prompter.askDefaults["App bundle identifier"], .some("com.jot"))
        XCTAssertFalse(prompter.transcript.joined().contains("Busy"), "leased devices are not offered")
        XCTAssertTrue(prompter.transcript.joined().contains("Equivalent command"))
        XCTAssertTrue(result.output.contains("amoo init down --manifest"))
        let saved = try String(contentsOfFile: agents, encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix("# Repo\n\nKeep me.\n"))
        XCTAssertTrue(saved.contains("<!-- amoo:init:start -->"))
        XCTAssertFalse(saved.contains("L-1"), "lease ids are never written to AGENTS.md")
        XCTAssertFalse(saved.contains("phone"), "device ids are never written to AGENTS.md")
        let locations = try XCTUnwrap(readInitLocations(agentsFile: agents))
        XCTAssertEqual(locations.appPath, URL(fileURLWithPath: app).standardizedFileURL.path)
        XCTAssertEqual(locations.appID, "com.jot")
        XCTAssertEqual(locations.manifestDirectory, URL(fileURLWithPath: out).deletingLastPathComponent().path)
    }

    func testDecliningOrWalkingAwayTouchesNothing() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let agents = scratch.url.appendingPathComponent("AGENTS.md").path
        let found = discovery(devices: [candidate("phone")], apps: [app], bundleID: "com.jot")
        let never = { (_: EnvUpOptions) async -> CLIResult in
            XCTFail("nothing may be set up")
            return CLIResult(output: "", exitCode: 0)
        }
        let declining = ScriptedPrompter()
        declining.confirms = [true, true, false] // launch, save locations, then refuse the final question
        var result = await runInitCommand(
            ["--agents-file", agents, "--no-skills"],
            runtime: runtime(prompter: declining, interactive: true, discovery: found, setup: never)
        )
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.hasPrefix("Cancelled"))
        let walkedAway = ScriptedPrompter()
        walkedAway.choices = [nil]
        result = await runInitCommand(
            ["--agents-file", agents, "--no-skills"],
            runtime: runtime(prompter: walkedAway, interactive: true, discovery: found, setup: never)
        )
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents), "nothing is saved unless the run proceeds")
    }

    func testSavingBothPlatformsPreservesLocationsAndRestoresMatchingDefaults() async throws {
        let scratch = try makeScratchDirectory()
        let agents = scratch.url.appendingPathComponent("AGENTS.md").path
        try "# Keep this\n".write(toFile: agents, atomically: true, encoding: .utf8)
        let app = try makeApp(in: scratch)
        let apk = scratch.url.appendingPathComponent("app.apk").path
        try Data("apk".utf8).write(to: URL(fileURLWithPath: apk))
        let ios = InitSavedLocations(
            platform: .ios, appPath: app, appID: "com.ios", manifestDirectory: scratch.url.path + "/ios"
        )
        let android = InitSavedLocations(
            platform: .android, appPath: apk, appID: "com.android", manifestDirectory: scratch.url.path + "/android"
        )
        try saveInitLocations(ios, agentsFile: agents)
        try saveInitLocations(android, agentsFile: agents)
        try saveInitLocations(ios, agentsFile: agents)
        let saved = try XCTUnwrap(readInitLocations(agentsFile: agents))
        XCTAssertEqual(saved.forPlatform(.android), android)
        XCTAssertEqual(saved.forPlatform(.ios)?.appPath, app)
        let text = try String(contentsOfFile: agents, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# Keep this\n"))
        XCTAssertEqual(text.components(separatedBy: "amoo:init:start").count, 2)
        for platform in [Platform.ios, .android] {
            let prompter = ScriptedPrompter()
            var request = InitRequest()
            request.platform = platform
            request.devices = ["phone"]
            let restored = try await completeInitRequest(
                request,
                discovery: discovery(devices: [candidate("phone")]),
                prompter: prompter,
                saved: saved
            )
            let expected = platform == .ios ? ios : android
            XCTAssertEqual(restored.appPath, expected.appPath)
            XCTAssertEqual(restored.appID, expected.appID)
            XCTAssertEqual(
                restored.out.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
                expected.manifestDirectory
            )
        }
    }

    func testSavedLocationsAreRemembered() {
        let base = "/repo"
        let saved = InitSavedLocations(
            platform: .ios,
            appPath: "/repo/build/Jot.app",
            appID: "com.jot",
            manifestDirectory: NSHomeDirectory() + "/.amoo/init"
        )
        let block = renderInitLocationsBlock(saved, relativeTo: base)
        XCTAssertTrue(block.contains("`build/Jot.app`"))
        XCTAssertTrue(block.contains("`~/.amoo/init`"))
        XCTAssertEqual(parseInitLocations(from: "intro\n" + block + "\ntail", relativeTo: base), saved)
        let once = upsertInitBlock(into: "# A\n", block: block)
        let twice = upsertInitBlock(into: once, block: renderInitLocationsBlock(
            InitSavedLocations(platform: .android, appPath: "/repo/app.apk", appID: "a.b", manifestDirectory: nil),
            relativeTo: base
        ))
        XCTAssertEqual(twice.components(separatedBy: "amoo:init:start").count, 2, "block is replaced, not duplicated")
        XCTAssertTrue(twice.hasPrefix("# A\n"))
        XCTAssertNil(parseInitLocations(from: "no block here", relativeTo: base))
    }

    func testSelectionParsingAndAppDiscovery() throws {
        XCTAssertEqual(parseSelection("1,3", count: 3), [0, 2])
        XCTAssertEqual(parseSelection("2-3", count: 3), [1, 2])
        XCTAssertEqual(parseSelection("ALL", count: 2), [0, 1])
        for bad in ["0", "4", "3-1", "x", ""] {
            XCTAssertNil(parseSelection(bad, count: 3), bad)
        }
        let scratch = try makeScratchDirectory()
        let products = scratch.url.appendingPathComponent("Build/Products/Debug-iphonesimulator")
        for name in ["Jot.app", "JotUITests-Runner.app"] {
            try FileManager.default.createDirectory(
                at: products.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(
            at: scratch.url.appendingPathComponent("Build/Products/Debug-iphoneos/Device.app"),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            discoverAppArtifacts(platform: .ios, roots: [scratch.url])
                .map { URL(fileURLWithPath: $0).lastPathComponent },
            ["Jot.app"]
        )
        let apk = scratch.url.appendingPathComponent("app/build/outputs/apk/debug")
        try FileManager.default.createDirectory(at: apk, withIntermediateDirectories: true)
        try Data().write(to: apk.appendingPathComponent("app-debug.apk"))
        try Data().write(to: apk.appendingPathComponent("app-debug-androidTest.apk"))
        XCTAssertEqual(
            discoverAppArtifacts(platform: .android, roots: [scratch.url])
                .map { URL(fileURLWithPath: $0).lastPathComponent },
            ["app-debug.apk"]
        )
    }

    func testGuidedFlowOffersAIClientSetupAndInstallsTheChosenOnes() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let prompter = ScriptedPrompter()
        prompter.multi = [[0], [1, 2]] // devices: first; AI clients: Cursor + Codex
        prompter.choices = [0, 0, 0, 1] // platform, app, scope = home directory
        prompter.confirms = [true, true, true, true, true] // launch, skills?, install files?, save, proceed
        prompter.asks = ["", "", scratch.url.appendingPathComponent("m.json").path]
        var installed: [AgentInstallOptions] = []
        let found = discovery(devices: [candidate("phone")], apps: [app], bundleID: "com.jot")
        let result = await runInitCommand(
            ["--agents-file", scratch.url.appendingPathComponent("AGENTS.md").path],
            runtime: runtime(
                prompter: prompter,
                interactive: true,
                discovery: found,
                setup: succeedingSetup,
                installAgents: { options in
                    installed.append(options)
                    return CLIResult(output: "installed", exitCode: 0)
                }
            )
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(installed.count, 1)
        XCTAssertEqual(installed.first?.clients, [.cursor, .codex])
        XCTAssertEqual(installed.first?.scope, .user)
        XCTAssertTrue(prompter.transcript.joined().contains("Codex (detected)"))
        XCTAssertTrue(result.output.contains("AI clients:\ninstalled"), result.output)
    }

    func testHeadlessInitInstallsSkillsOnlyWhenClientsAreNamed() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let found = discovery(devices: [candidate("phone")])
        let ok = succeedingSetup
        let base = ["--platform", "ios", "--app", app, "--app-id", "com.jot", "--device", "phone", "--non-interactive"]
        var installed: [AgentInstallOptions] = []
        _ = await runInitCommand(base + ["--client", "claude,codex"], runtime: runtime(
            discovery: found,
            setup: ok,
            installAgents: { installed.append($0); return CLIResult(output: "", exitCode: 0) }
        ))
        XCTAssertEqual(installed.first?.clients, [.claude, .codex])
        XCTAssertEqual(installed.first?.scope, .project)
        _ = await runInitCommand(base, runtime: runtime(discovery: found, setup: ok)) // installAgents would XCTFail
        XCTAssertThrowsError(try parseInitRequest(["--json", "--client", "codex"]))
        XCTAssertThrowsError(try parseInitRequest(["--no-skills", "--client", "codex"]))
    }

    func testStandaloneAgentInstallAsksWhichClientsAndWhere() throws {
        let scratch = try makeScratchDirectory()
        let prompter = ScriptedPrompter()
        prompter.multi = [[2]] // Codex
        prompter.choices = [0] // this repository
        let args = ["--target", scratch.url.path]
        let result = runAgentInstallCommand(
            args,
            prompter: prompter,
            interactive: { true },
            detected: { [.codex] },
            assetsRoot: pluginRoot
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: scratch.url.appendingPathComponent(".codex/agents/amoo.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent(".claude").path))
        XCTAssertFalse(prompter.transcript.joined().contains("Install for"), "--target already answered the scope")

        let declined = ScriptedPrompter()
        declined.confirms = [false]
        let other = try makeScratchDirectory()
        let cancelled = runAgentInstallCommand(
            ["--target", other.url.path],
            prompter: declined,
            interactive: { true },
            detected: { [] },
            assetsRoot: pluginRoot
        )
        XCTAssertEqual(cancelled.exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.url.appendingPathComponent(".claude").path))

        // Scripted use keeps working: --client (or no terminal) never prompts.
        let silent = ScriptedPrompter()
        let scripted = runAgentInstallCommand(
            ["--target", other.url.path, "--client", "claude"],
            prompter: silent,
            interactive: { true },
            assetsRoot: pluginRoot
        )
        XCTAssertEqual(scripted.exitCode, 0, scripted.output)
        XCTAssertTrue(silent.transcript.isEmpty)
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: other.url.appendingPathComponent(".claude/agents/amoo.md").path))
    }

    func testClientDetectionUsesPerUserConfigDirectories() {
        let present: Set = ["/h/.claude", "/h/.config/opencode"]
        XCTAssertEqual(detectInstalledAgentClients(home: "/h", exists: { present.contains($0) }), [.claude, .opencode])
    }
}
