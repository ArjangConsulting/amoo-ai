@testable import CLI
import Foundation
import XCTest

/// Guided `amoo init` offers to add a sign-in account once, and never stops device setup over it.
final class InitSignInPromptTests: InitTestCase {
    private struct GuidedRun {
        var result: CLIResult
        var prompter: ScriptedPrompter
        var agents: String
    }

    private func runGuidedInit(
        confirms: [Bool?],
        addCredentials: @escaping (CredentialsAddDefaults) -> CLIResult
    ) async throws -> GuidedRun {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let agents = scratch.url.appendingPathComponent("AGENTS.md").path
        let prompter = ScriptedPrompter()
        prompter.choices = [0, 0]
        prompter.multi = [[0]]
        prompter.asks = ["", scratch.url.appendingPathComponent("run.json").path]
        prompter.confirms = confirms
        var initRuntime = runtime(
            prompter: prompter,
            interactive: true,
            discovery: discovery(devices: [candidate("phone")], bundleID: "com.jot")
        ) { _ in
            CLIResult(
                output: renderJSON(EnvUpReport(ok: true, runtimeID: "L", platform: "ios", port: 22000)),
                exitCode: 0
            )
        }
        initRuntime.addCredentials = { defaults, _, _ in addCredentials(defaults) }
        let result = await runInitCommand(["--agents-file", agents, "--no-skills", "--app", app], runtime: initRuntime)
        return GuidedRun(result: result, prompter: prompter, agents: agents)
    }

    func testGuidedInitOffersToAddASignInAccountWithTheAppID() async throws {
        var offered: CredentialsAddDefaults?
        // launch the app, save setup, prepare devices, sign in
        let run = try await runGuidedInit(confirms: [true, true, true, true]) { defaults in
            offered = defaults
            return CLIResult(output: "Saved profile", exitCode: 0)
        }
        XCTAssertEqual(run.result.exitCode, 0, run.result.output)
        XCTAssertEqual(offered, CredentialsAddDefaults(appID: "com.jot"))
        XCTAssertTrue(run.prompter.transcript.contains { $0.hasPrefix("Will agents need to sign in") })
    }

    func testDecliningSignInPointsAtTheCommandForLater() async throws {
        let run = try await runGuidedInit(confirms: [true, true, true, false]) { _ in
            XCTFail("credentials must not be added")
            return CLIResult(output: "", exitCode: 1)
        }
        XCTAssertEqual(run.result.exitCode, 0, run.result.output)
        XCTAssertTrue(run.prompter.transcript.contains("Add a sign-in account any time with `amoo credentials add`."))
        XCTAssertTrue(run.result.output.contains("amoo credentials add"))
        XCTAssertTrue(try String(contentsOfFile: run.agents, encoding: .utf8).contains("`amoo credentials add`"))
    }

    func testAFailedOrCancelledAccountDoesNotStopDeviceSetup() async throws {
        let run = try await runGuidedInit(confirms: [true, true, true, true]) { _ in
            CLIResult(output: "Cancelled. No account was saved.", exitCode: 1)
        }
        XCTAssertEqual(run.result.exitCode, 0, run.result.output)
        XCTAssertTrue(run.prompter.transcript.contains { $0.contains("Run `amoo credentials add` to try again.") })
    }

    func testHeadlessInitNeverAsksAboutSignIn() async throws {
        let scratch = try makeScratchDirectory()
        let prompter = ScriptedPrompter()
        var initRuntime = runtime(
            prompter: prompter,
            discovery: discovery(devices: [candidate("phone")], bundleID: nil)
        ) { _ in
            CLIResult(
                output: renderJSON(EnvUpReport(ok: true, runtimeID: "L", platform: "ios", port: 22000)),
                exitCode: 0
            )
        }
        initRuntime.addCredentials = { _, _, _ in
            XCTFail("headless init must not offer credentials")
            return CLIResult(output: "", exitCode: 1)
        }
        _ = await runInitCommand(
            [
                "--platform",
                "ios",
                "--device",
                "phone",
                "--no-skills",
                "--out",
                scratch.url.appendingPathComponent("r.json").path
            ],
            runtime: initRuntime
        )
        XCTAssertFalse(prompter.transcript.contains { $0.contains("sign in") })
    }
}
