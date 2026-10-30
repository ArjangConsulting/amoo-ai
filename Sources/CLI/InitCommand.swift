import AmooCore
import Foundation
import StudioProtocol

/// Independent controlled environments, an optional explicit artifact, and no recording transport.
struct InitOptions {
    var environment: EnvUpOptions
    var devices: [String]
    var out: String?
    var framework: String?
    /// The platform repository, relative to the directory holding `AGENTS.md`. Nil when that directory
    /// is itself the repository.
    var repo: String?
}

/// Versioned CLI setup manifest. Runtime tokens are ownership credentials; keep this file private.
struct InitManifest: Codable {
    var schemaVersion = 2
    var ok: Bool
    var results: [EnvUpReport]
    var error: String?

    static func read(_ path: String) throws -> Self {
        try decodeMigrating(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Atomic replace, created 0600 from the start: the file holds runtime ids, so there is no
    /// window in which it is readable by anyone else.
    func write(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if url.lastPathComponent == ".amoo.json" {
            let ignore = directory.appendingPathComponent(".gitignore")
            let existing = FileManager.default.fileExists(atPath: ignore.path)
                ? try String(contentsOf: ignore, encoding: .utf8) : ""
            if !existing.split(separator: "\n").contains("/.amoo.json") {
                let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
                try (existing + separator + "/.amoo.json\n").write(to: ignore, atomically: true, encoding: .utf8)
            }
        }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: Data(renderJSON(self).utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw EnvCommandParseError.usage("Cannot create \(temporary.path).") }
        // POSIX rename replaces atomically on every platform; Foundation's replaceItemAt fails on
        // Linux (swift-corelibs-foundation) when the destination already exists.
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

func renderInitHelp() -> String {
    """
    Usage: amoo init                      guided setup (asks for anything not given)
           amoo init --platform ios|android --device <id> [--device <id> ...]
                     [--app <absolute-build-path> --app-id <id>] [--launch|--no-launch] [--owner <label>]
                     [--ttl <minutes>] [--ready-timeout <seconds>] [--out <manifest.json>]
                     [--framework native|react-native|flutter|kmp] [--repo <dir>]
                     [--dry-run] [--yes] [--save|--no-save] [--agents-file <path>]
                     [--client <name>]... [--skills|--no-skills]
                     [--non-interactive] [--json]
           amoo init device [--manifest <path>] --device <id> [--json] <tool> [key=value ...]
           amoo init down [--manifest <path>] [--shutdown] [--json]
           amoo init repo [--target <repo>] [--client <name> ...] [--dry-run] [--json]

    Prepare devices without supplying an app build. Each gets its own runtime and companion port
    through the same code as `env up`. To also install an app, explicitly pass --app and --app-id.

    In a terminal, `amoo init` walks you through device selection, shows the plan with the equivalent
    command, and asks before starting anything. It never asks for a build path or searches for builds.
    Flags you pass are kept and not asked again. With --json, --non-interactive or no terminal it
    never prompts: --platform and --device are required; --app-id is also required when supplying
    --app or --launch. Every missing input is reported at once. --dry-run validates without starting runtimes.

    The platform, manifest directory and any explicitly supplied app are recorded in ./AGENTS.md
    (asked in a terminal; --save to do it headless). Guided setup defaults to ./.amoo.json;
    saved app paths are never selected automatically. Device and runtime ids are never saved in AGENTS.md.
    In a terminal it also asks whether agents need to sign in, and if so runs `amoo credentials add`
    to save a test account (mock in amoo.config.json, real in the macOS Keychain). The saved block and
    the summary say whether sign-in profiles exist; add more any time with `amoo credentials add`.

    In a terminal it also offers to set up the amoo subagents and skills for your AI clients (Claude
    Code, Cursor, Codex, Copilot, Gemini, OpenCode), using the same picker as `amoo agent install`.
    Current installs skip the picker; outdated or missing files get one update confirmation.
    Headless, existing drift prints an `amoo agent update` hint; pass --client to install.
    --no-skills skips AI client setup. Run from the orchestrator root for submodule layouts.

    --repo <dir> names the platform's repository below the orchestrator root (for example
    `--platform ios --repo iOS`; a React Native app uses ios/ and android/ the same way). Run it once per
    platform. The platform's amoo.md and default manifest (<dir>/.amoo.json) are written inside that
    repository, and the root amoo.md records the repo for the platform, so later `init down` and
    `init device` find the manifest without --manifest.

    Validation runs first (app exists and matches --app-id, every device exists and is available);
    no runtime starts if it fails. All results are returned, including failures; exit 1 means at
    least one failed. --out writes the same JSON incrementally, so an interrupted run still
    records the runtimes it started. Companion products may be built when missing or changed; the
    supplied app is never built.
    device selects one successful manifest entry and proves ownership with its runtime.
    down stops every successful entry through env down, respecting active device access locks.
    Without --manifest, device and down use ./.amoo.json and the .amoo.json of each repository
    that amoo.md names in `repo`.
    repo is `amoo agent install` (guided in a terminal) for when you only want the AI client setup.
    Treat manifests as private credentials. For recording, stop CLI runtimes first, then
    use MCP start_session with device_hint and the app's build_path; end_session exports the plan.
    """
}

private func previousInitConnections(at path: String?) throws -> [EnvUpReport] {
    guard let path, FileManager.default.fileExists(atPath: path) else { return [] }
    return try InitManifest.read(path).results.filter { $0.runtimeID != nil }
}

// Runs each device through `env up` in turn. `onProgress` narrates for a terminal; the manifest is
// rewritten after every device so a killed run never leaves runtimes that nothing records.
// swiftlint:disable:next function_body_length
func runInit(
    _ options: InitOptions,
    setup: (EnvUpOptions) async -> CLIResult = { await runEnvUp($0) },
    onProgress: ((String) -> Void)? = nil
) async -> CLIResult {
    let previous: [EnvUpReport]
    do { previous = try previousInitConnections(at: options.out) } catch {
        let message = "Cannot read existing device connections: \(error)"
        return CLIResult(
            output: options.environment.json
                ? renderJSON(InitManifest(ok: false, results: [], error: message)) : message,
            exitCode: 1
        )
    }
    var results: [EnvUpReport] = []
    let app = EnvAppReport(
        id: options.environment.appID,
        path: options.environment.appPath,
        sha256: options.environment.appSHA256 ?? options.environment.appPath.flatMap { sha256Hex(ofPath: $0) },
        installed: false,
        launched: false
    )
    var manifest = InitManifest(ok: true, results: previous)
    func persist() {
        guard let out = options.out else { return }
        do { try manifest.write(out) } catch {
            manifest.error = "Cannot write manifest: \(error). Use the returned runtimes for cleanup."
        }
    }
    // Verify persistence before taking ownership of any device.
    persist()
    if let error = manifest.error {
        manifest.ok = false
        return CLIResult(output: options.environment.json ? renderJSON(manifest) : error, exitCode: 1)
    }
    // Sequential setup lets env up see each preceding runtime/port and keeps companion builds serialized.
    for (index, device) in options.devices.enumerated() {
        let step = "[\(index + 1)/\(options.devices.count)]"
        onProgress?("\(step) Preparing \(device)…")
        var environment = options.environment
        environment.deviceID = device
        environment.json = true
        environment.appSHA256 = app.sha256
        let result = await setup(environment)
        var report = (try? JSONDecoder().decode(EnvUpReport.self, from: Data(result.output.utf8)))
            ?? EnvUpReport(ok: false, platform: environment.platform.rawValue, error: result.output)
        if report.device == nil {
            report.device = EnvDeviceReport(id: device, bootedByEnv: false)
        }
        if report.app == nil, app.id != nil || app.path != nil {
            report.app = app
        }
        results.append(report)
        // Retain credentials for other devices/platforms and failed attempts to replace a device.
        manifest.results = results + previous.filter { old in
            !results.contains { new in
                new.runtimeID == old
                    .runtimeID || (new.ok && new.platform == old.platform && new.device?.id == old.device?.id)
            }
        }
        manifest.ok = results.allSatisfy(\.ok)
        persist()
        if manifest.error != nil {
            break
        }
        onProgress?(report.ok
            ? "\(step) Ready: runtime \(report.runtimeID ?? "?"), port \(report.port.map(String.init) ?? "?")"
            : "\(step) Failed: \(report.error ?? "unknown error")")
    }
    manifest.ok = results.allSatisfy(\.ok) && manifest.error == nil
    let output = options.environment.json ? renderJSON(manifest)
        : results.map(\.humanSummary).joined(separator: "\n\n")
        + (manifest.error.map { "\n\($0)" } ?? "")
    return CLIResult(output: output, exitCode: manifest.ok ? 0 : 1)
}

func runInitDown(
    _ manifest: InitManifest,
    shutdown: Bool,
    cleanup: (EnvDownOptions) async -> CLIResult = { await runEnvDown($0) }
) async -> CLIResult {
    var results: [EnvDownReport] = []
    for entry in manifest.results where entry.ok {
        guard let runtime = entry.runtimeID else {
            results.append(EnvDownReport(
                ok: false,
                device: entry.device?.id,
                companionStopped: false,
                shutdown: false,
                error: "Successful manifest entry has no runtime."
            ))
            continue
        }
        let result = await cleanup(EnvDownOptions(runtimeID: runtime, shutdown: shutdown, json: true))
        results.append((try? JSONDecoder().decode(EnvDownReport.self, from: Data(result.output.utf8)))
            ?? EnvDownReport(
                ok: false,
                runtimeID: runtime,
                companionStopped: false,
                shutdown: false,
                error: result.output
            ))
    }
    let ok = results.allSatisfy(\.ok)
    return CLIResult(output: renderJSON(InitDownReport(ok: ok, results: results)), exitCode: ok ? 0 : 1)
}

private struct InitDownReport: Codable {
    var ok: Bool
    var results: [EnvDownReport]
}

func initDeviceArguments(_ manifest: InitManifest, device: String, args: [String]) throws -> [String] {
    guard let entry = manifest.results.first(where: { $0.ok && $0.device?.id == device }),
          let runtime = entry.runtimeID, let port = entry.port
    else { throw EnvCommandParseError.usage("No successful init entry for device \(device).") }
    // Leading routing flags cannot override the entry's ownership or transport.
    guard !args.contains(where: { ["--runtime-id", "--port", "--platform", "--device"].contains($0) }) else {
        throw EnvCommandParseError.usage("Manifest supplies platform, device, port and runtime.")
    }
    return ["--platform", entry.platform, "--device", device, "--port", String(port), "--runtime-id", runtime] + args
}

func handleInitCommand(remaining: [String], runtime: InitRuntime = .live()) async -> CLIResult {
    if isHelpRequest(remaining) {
        return CLIResult(output: renderInitHelp(), exitCode: 0)
    }
    if remaining.first == "repo" {
        return handleAgentCommand(remaining: ["install"] + remaining.dropFirst())
    }
    guard remaining.first == "down" || remaining.first == "device" else {
        return await runInitCommand(remaining, runtime: runtime)
    }
    do {
        var args = Array(remaining.dropFirst())
        let manifestPaths: [String]
        if let index = args.firstIndex(of: "--manifest"), args.indices.contains(index + 1) {
            manifestPaths = [args[index + 1]]
            args.removeSubrange(index ... index + 1)
        } else {
            manifestPaths = discoverInitManifests()
            guard !manifestPaths.isEmpty else {
                throw EnvCommandParseError.usage(
                    "--manifest <path> is required: no .amoo.json here or in a repository that amoo.md names in `repo`."
                )
            }
        }
        let manifests = try manifestPaths.map { try InitManifest.read($0) }
        if remaining.first == "down" {
            var flags = EnvFlagReader(args)
            let shutdown = flags.take("--shutdown")
            let json = flags.take("--json")
            try flags.finish()
            var results: [CLIResult] = []
            for (path, manifest) in zip(manifestPaths, manifests) {
                let result = await runInitDown(manifest, shutdown: shutdown)
                if result.exitCode == 0 {
                    try InitManifest(ok: true, results: []).write(path)
                }
                results.append(result)
            }
            let combined = combineInitDownResults(results)
            return json ? combined : CLIResult(
                output: combined.exitCode == 0 ? "Stopped initialized runtimes." : combined.output,
                exitCode: combined.exitCode
            )
        }
        guard let index = args.firstIndex(of: "--device"), args.indices.contains(index + 1) else {
            throw EnvCommandParseError.usage("--device <id> is required.")
        }
        let device = args[index + 1]
        args.removeSubrange(index ... index + 1)
        let owner = manifests.first { $0.results.contains { $0.ok && $0.device?.id == device } } ?? manifests[0]
        return try await CLIApp().run(args: ["device"] + initDeviceArguments(owner, device: device, args: args))
    } catch {
        return initFailure(error, json: remaining.contains("--json"))
    }
}

/// The manifests `init down` and `init device` use when `--manifest` is absent: `.amoo.json` in the working
/// directory and in each platform repository an `amoo.md` names in `repo`.
func discoverInitManifests(
    from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
) -> [String] {
    var candidates = [directory.appendingPathComponent(".amoo.json")]
    for platform in [Platform.ios, .android] {
        if let repo = try? RepositoryTestProfile.repositoryDirectory(for: platform, from: directory) {
            candidates.append(repo.appendingPathComponent(".amoo.json"))
        }
    }
    var seen = Set<String>()
    return candidates.map(\.standardizedFileURL.path).filter {
        FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted
    }
}

/// One report for several manifests: every entry, and the worst exit code.
func combineInitDownResults(_ results: [CLIResult]) -> CLIResult {
    guard results.count > 1 else { return results.first ?? CLIResult(output: "", exitCode: 0) }
    let reports = results.compactMap { try? JSONDecoder().decode(InitDownReport.self, from: Data($0.output.utf8)) }
    guard reports.count == results.count else {
        return CLIResult(
            output: results.map(\.output).joined(separator: "\n"),
            exitCode: results.map(\.exitCode).max() ?? 1
        )
    }
    let all = reports.flatMap(\.results)
    let ok = reports.allSatisfy(\.ok)
    return CLIResult(output: renderJSON(InitDownReport(ok: ok, results: all)), exitCode: ok ? 0 : 1)
}

/// Keeps usage and file errors machine-readable whenever JSON was requested.
func initFailure(_ error: any Error, json: Bool) -> CLIResult {
    CLIResult(
        output: json ? renderJSON(InitManifest(ok: false, results: [], error: String(describing: error)))
            : "\(error)\n\n" + renderInitHelp(),
        exitCode: 64
    )
}
