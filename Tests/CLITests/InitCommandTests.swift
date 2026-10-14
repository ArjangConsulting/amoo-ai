import AmooCore
@testable import CLI
import Foundation
import MobileDevices
import TestCommons
import XCTest

/// Answers queued per call kind; `nil` in the queue means end of input.
final class ScriptedPrompter: CLIPrompting {
    var asks: [String?] = []
    var confirms: [Bool?] = []
    var choices: [Int?] = []
    var multi: [[Int]?] = []
    private(set) var transcript: [String] = []
    private(set) var askDefaults: [String: String?] = [:]

    func say(_ text: String) {
        transcript.append(text)
    }

    func ask(_ prompt: String, default defaultValue: String?) -> String? {
        transcript.append(prompt)
        askDefaults[prompt] = defaultValue
        guard !asks.isEmpty else { return defaultValue }
        let answer = asks.removeFirst()
        return answer.map { $0.isEmpty ? (defaultValue ?? "") : $0 }
    }

    func confirm(_ prompt: String, default defaultAnswer: Bool) -> Bool? {
        transcript.append(prompt)
        return confirms.isEmpty ? defaultAnswer : confirms.removeFirst()
    }

    func choose(_ prompt: String, options: [String], default index: Int) -> Int? {
        transcript.append(prompt + ": " + options.joined(separator: " | "))
        return choices.isEmpty ? index : choices.removeFirst()
    }

    func chooseMany(_ prompt: String, options: [String], defaults: [Int]) -> [Int]? {
        transcript.append(prompt + ": " + options.joined(separator: " | "))
        return multi.isEmpty ? defaults : multi.removeFirst()
    }
}

class InitTestCase: XCTestCase {
    func candidate(_ id: String, booted: Bool = true, leasedBy: String? = nil) -> InitDeviceCandidate {
        InitDeviceCandidate(id: id, name: id.capitalized, detail: "iOS 27.0", booted: booted, leasedBy: leasedBy)
    }

    func discovery(
        devices: [InitDeviceCandidate],
        apps: [String] = [],
        bundleID: String? = nil
    ) -> InitDiscovery {
        InitDiscovery(devices: { _ in devices }, apps: { _ in apps }, bundleID: { _, _ in bundleID })
    }

    /// A `setup` standing in for a successful `env up`.
    var succeedingSetup: (EnvUpOptions) async -> CLIResult {
        { _ in
            CLIResult(output: renderJSON(EnvUpReport(ok: true, lease: "L", platform: "ios", port: 22000)), exitCode: 0)
        }
    }

    /// A `setup` that fails the test if anything tries to lease a device.
    func forbidden(_ message: String) -> (EnvUpOptions) async -> CLIResult {
        { _ in
            XCTFail(message)
            return CLIResult(output: "", exitCode: 0)
        }
    }

    func makeApp(in scratch: TemporaryDirectory) throws -> String {
        let app = scratch.url.appendingPathComponent("Jot.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("one-build".utf8).write(to: app.appendingPathComponent("binary"))
        return app.path
    }

    func flags(app: String, extra: [String] = []) -> [String] {
        [
            "--platform", "ios", "--app", app, "--app-id", "com.jot",
            "--device", "phone", "--device", "tablet", "--launch", "--owner", "agent", "--json"
        ] + extra
    }

    func runtime(
        prompter: ScriptedPrompter = ScriptedPrompter(),
        interactive: Bool = false,
        discovery: InitDiscovery,
        setup: @escaping (EnvUpOptions) async -> CLIResult,
        installAgents: @escaping (AgentInstallOptions) -> CLIResult = { _ in
            XCTFail("skills must not be installed")
            return CLIResult(output: "", exitCode: 0)
        }
    ) -> InitRuntime {
        InitRuntime(
            discovery: discovery,
            prompter: prompter,
            isInteractive: { interactive },
            setup: setup,
            now: { Date(timeIntervalSince1970: 0) },
            detectedClients: { [.codex] },
            installAgents: installAgents,
            assetsRoot: pluginRoot
        )
    }

    var pluginRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("plugins/amoo")
    }
}

final class InitCommandTests: InitTestCase {
    func testRepeatedDeviceParsingAndInvalidOptions() throws {
        let request = try parseInitRequest(flags(app: "/tmp/Jot.app"))
        XCTAssertEqual(request.devices, ["phone", "tablet"])
        XCTAssertEqual(request.appPath, "/tmp/Jot.app")
        XCTAssertEqual(request.owner, "agent")
        XCTAssertEqual(request.launch, true)
        XCTAssertTrue(request.missing.isEmpty)
        XCTAssertEqual(try parseInitRequest(["--no-launch"]).launch, false)
        XCTAssertEqual(try parseInitRequest([]).missing.count, 4)
        for bad in [
            ["--device", "phone", "--device", "phone"],
            ["--port", "22093"],
            ["--avd", "Pixel"],
            ["--platform", "windows"],
            ["--device"],
            ["--out", "/tmp/a.json", "--out", "/tmp/b.json"],
            ["--launch", "--no-launch"],
            ["--save", "--no-save"]
        ] {
            XCTAssertThrowsError(try parseInitRequest(bad), "\(bad)")
        }
    }

    func testHeadlessRunNamesEveryMissingInputAndWhatIsAvailable() async {
        let found = discovery(devices: [candidate("phone"), candidate("tablet", leasedBy: "x")], apps: ["/b/Jot.app"])
        let result = await runInitCommand(
            ["--platform", "ios", "--non-interactive"],
            runtime: runtime(discovery: found, setup: forbidden("must not set up"))
        )
        XCTAssertEqual(result.exitCode, 64)
        for expected in ["--app <", "--app-id <", "--device <", "/b/Jot.app", "Phone", "amoo init"] {
            XCTAssertTrue(result.output.contains(expected), "\(expected) in \(result.output)")
        }
        XCTAssertFalse(result.output.contains("--platform ios|android"))
        let json = await runInitCommand(
            ["--json"],
            runtime: runtime(interactive: true, discovery: found) { _ in CLIResult(output: "", exitCode: 0) }
        )
        XCTAssertEqual(json.exitCode, 64, "--json never prompts even in a terminal")
        XCTAssertTrue(json.output.hasPrefix("{"), json.output)
    }

    func testSharedArtifactIndependentLeasesPortsManifestAndCleanup() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let before = sha256Hex(ofPath: app)
        let store = DeviceClaimStore(directory: scratch.url.appendingPathComponent("leases"))
        let out = scratch.url.appendingPathComponent("nested/manifest.json").path
        var installed: [(path: String?, sha: String?)] = []
        var manifestSeenByLastDevice: InitManifest?
        let dependencies = EnvUpDependencies(resolve: { options, _ in
            try EnvDeviceReport(id: XCTUnwrap(options.deviceID), name: options.deviceID, bootedByEnv: false)
        }, start: { _, lease, store in
            var lease = lease
            lease.port = await pickFreeCompanionPort(leasedPorts: Set(store.all().compactMap(\.port))) { _ in false }
            return try store.renew(lease)
        }, prepare: { options, _, app in
            installed.append((options.appPath, options.appSHA256))
            app?.installed = true
            app?.launched = options.launch
        })
        let found = discovery(devices: [candidate("phone"), candidate("tablet")])
        let result = await runInitCommand(
            flags(app: app, extra: ["--out", out]),
            runtime: runtime(discovery: found) { options in
                if options.deviceID == "tablet" {
                    manifestSeenByLastDevice = try? InitManifest.read(out)
                }
                return await runEnvUp(options, store: store, dependencies: dependencies)
            }
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        let manifest = try InitManifest.read(out)
        XCTAssertEqual(result.output, renderJSON(manifest))
        XCTAssertEqual(manifestSeenByLastDevice?.results.count, 1, "manifest is written after each device")
        XCTAssertEqual(installed.map(\.path), [app, app])
        XCTAssertEqual(installed.map(\.sha), [before, before], "digest computed once and shared")
        XCTAssertEqual(Set(manifest.results.compactMap(\.lease)).count, 2)
        XCTAssertEqual(Set(manifest.results.compactMap(\.port)).count, 2)
        XCTAssertTrue(manifest.results.allSatisfy { $0.app?.sha256 == before && $0.app?.launched == true })
        XCTAssertEqual(sha256Hex(ofPath: app), before, "the artifact is never modified")
        let mode = try FileManager.default.attributesOfItem(atPath: out)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let routed = try initDeviceArguments(manifest, device: "tablet", args: ["--json", "current_app"])
        let parsed = try parseDeviceCommandOptions(args: routed).get()
        XCTAssertEqual(parsed.lease, manifest.results[1].lease)
        XCTAssertEqual(parsed.port, manifest.results[1].port)
        XCTAssertThrowsError(try initDeviceArguments(
            manifest,
            device: "tablet",
            args: ["--lease", "other", "current_app"]
        ))
        let cleanup = await runInitDown(manifest, shutdown: false) { await runEnvDown($0, store: store) }
        XCTAssertEqual(cleanup.exitCode, 0, cleanup.output)
        XCTAssertTrue(store.all().isEmpty)
    }

    func testPartialFailureKeepsInstallStatusAndNeverTakesAnotherSessionsLease() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let store = DeviceClaimStore(directory: scratch.url.appendingPathComponent("leases"))
        let other = try store.acquire(platform: .ios, deviceID: "phone", deviceName: "Phone", owner: "someone-else")
        var starts: [String] = []
        let dependencies = EnvUpDependencies(resolve: { options, _ in
            try EnvDeviceReport(id: XCTUnwrap(options.deviceID), name: options.deviceID, bootedByEnv: false)
        }, start: { _, lease, store in
            starts.append(lease.deviceID)
            var lease = lease
            lease.port = 22093 + starts.count
            return try store.renew(lease)
        }, prepare: { options, _, app in
            app?.installed = true
            if options.deviceID == "broken" {
                throw EnvError.appFailed("launch failed")
            }
            app?.launched = true
        })
        let found = discovery(devices: [
            candidate("phone", leasedBy: other.summary),
            candidate("tablet"),
            candidate("broken")
        ])
        let result = await runInitCommand(
            flags(app: app, extra: ["--device", "broken"]),
            runtime: runtime(discovery: found) { await runEnvUp($0, store: store, dependencies: dependencies) }
        )
        let manifest = try JSONDecoder().decode(InitManifest.self, from: Data(result.output.utf8))
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(manifest.results.map(\.ok), [false, true, false])
        XCTAssertEqual(starts, ["tablet", "broken"], "a leased device never reaches the companion step")
        XCTAssertTrue(manifest.results[0].error?.contains("someone-else") == true)
        XCTAssertEqual(manifest.results[2].app?.installed, true)
        XCTAssertEqual(manifest.results[2].app?.launched, false)
        let cleanup = await runInitDown(manifest, shutdown: false) { await runEnvDown($0, store: store) }
        XCTAssertEqual(cleanup.exitCode, 0)
        XCTAssertEqual(store.all().map(\.id), [other.id])
    }

    func testArtifactProblemsStopBeforeAnyLease() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let found = discovery(devices: [candidate("phone"), candidate("tablet")], bundleID: "com.other")
        let never = runtime(discovery: found, setup: forbidden("nothing may be leased"))
        let mismatch = await runInitCommand(flags(app: app), runtime: never)
        XCTAssertEqual(mismatch.exitCode, 1)
        XCTAssertTrue(mismatch.output.contains("com.other"), mismatch.output)
        let missing = await runInitCommand(
            flags(app: scratch.url.appendingPathComponent("Nope.app").path),
            runtime: never
        )
        XCTAssertTrue(missing.output.contains("init never builds the app"), missing.output)
        let relative = await runInitCommand(flags(app: "Jot.app"), runtime: never)
        XCTAssertTrue(relative.output.contains("absolute"), relative.output)
        let allLeased = discovery(devices: [candidate("phone", leasedBy: "a"), candidate("tablet", leasedBy: "b")])
        let refused = await runInitCommand(flags(app: app), runtime: runtime(
            discovery: allLeased,
            setup: forbidden("nothing may be leased")
        ))
        XCTAssertEqual(refused.exitCode, 1)
        XCTAssertTrue(refused.output.contains("already leased"), refused.output)
    }

    func testDryRunReportsThePlanWithoutLeasing() async throws {
        let scratch = try makeScratchDirectory()
        let app = try makeApp(in: scratch)
        let found = discovery(devices: [candidate("phone"), candidate("tablet", leasedBy: "x")])
        let result = await runInitCommand(
            flags(app: app, extra: ["--dry-run"]),
            runtime: runtime(discovery: found, setup: forbidden("dry run must not set up"))
        )
        XCTAssertEqual(result.exitCode, 1, "a leased device is a problem even in a dry run")
        XCTAssertTrue(result.output.contains("\"dryRun\":true"), result.output)
        XCTAssertTrue(result.output.contains("already leased"), result.output)
        XCTAssertTrue(result.output.contains("--non-interactive"), result.output)
    }

    func testCleanupContinuesAfterFailureAndManifestVersionIsChecked() async throws {
        let entries = ["a", "b"].map { EnvUpReport(ok: true, lease: $0, platform: "ios") }
        var leases: [String?] = []
        let result = await runInitDown(InitManifest(ok: true, results: entries), shutdown: false) { options in
            leases.append(options.lease)
            return CLIResult(output: renderJSON(EnvDownReport(
                ok: options.lease == "b",
                lease: options.lease,
                holderStopped: true,
                shutdown: false
            )), exitCode: 1)
        }
        XCTAssertEqual(leases, ["a", "b"])
        XCTAssertEqual(result.exitCode, 1)
        let out = try makeScratchDirectory().url.appendingPathComponent("manifest.json").path
        try InitManifest(schemaVersion: 2, ok: true, results: []).write(out)
        XCTAssertThrowsError(try InitManifest.read(out))
    }

    func testRepoInitReusesInstallerDryRun() async {
        let app = CLIApp()
        let result = await app.run(args: ["init", "repo", "--client", "codex", "--dry-run", "--json"])
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains(".agents/skills"), result.output)
        XCTAssertTrue(result.output.contains(".codex/agents"), result.output)
    }
}
