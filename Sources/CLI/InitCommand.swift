import AmooCore
import Foundation

/// One reusable artifact, independent leased environments, and no recording transport.
struct InitOptions {
    var environment: EnvUpOptions
    var devices: [String]
    var out: String?
}

/// Versioned CLI setup manifest. Lease tokens are ownership credentials; keep this file private.
struct InitManifest: Codable {
    var schemaVersion = 1
    var ok: Bool
    var results: [EnvUpReport]
    var error: String?

    static func read(_ path: String) throws -> Self {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard manifest.schemaVersion == 1 else {
            throw EnvCommandParseError.usage("Unsupported init manifest version \(manifest.schemaVersion).")
        }
        return manifest
    }

    /// Atomic replace, created 0600 from the start: the file holds lease ids, so there is no
    /// window in which it is readable by anyone else.
    func write(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: Data(renderJSON(self).utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw EnvCommandParseError.usage("Cannot create \(temporary.path).") }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

func renderInitHelp() -> String {
    """
    Usage: amoo init                      guided setup (asks for anything not given)
           amoo init --platform ios|android --app <absolute-build-path> --app-id <id>
                     --device <id> [--device <id> ...] [--launch|--no-launch] [--owner <label>]
                     [--ttl <minutes>] [--ready-timeout <seconds>] [--out <manifest.json>]
                     [--dry-run] [--yes] [--save|--no-save] [--agents-file <path>]
                     [--client <name>]... [--skills|--no-skills]
                     [--non-interactive] [--json]
           amoo init device --manifest <path> --device <id> [--json] <tool> [key=value ...]
           amoo init down --manifest <path> [--shutdown] [--json]
           amoo init repo [--target <repo>] [--client <name> ...] [--dry-run] [--json]

    Build your app once, externally. Init reuses that artifact unchanged on every device, giving
    each its own lease, companion and port through the same code as `env up`.

    In a terminal, `amoo init` walks you through it: it finds built apps and simulators, reads the
    bundle id from the app, shows the plan with the equivalent command, and asks before leasing
    anything. Flags you pass are kept and not asked again. With --json, --non-interactive or no
    terminal it never prompts: all of --platform, --app, --app-id and --device are required, and
    every missing one is reported at once. --dry-run validates and prints the plan without leasing.

    The app location and manifest directory are recorded in ./AGENTS.md (asked in a terminal;
    --save to do it headless) and offered as defaults next time. Device and lease ids are never saved.

    In a terminal it also offers to set up the amoo subagents and skills for your AI clients (Claude
    Code, Cursor, Codex, Copilot, Gemini, OpenCode), using the same picker as `amoo agent install`.
    Headless, pass --client to do so; --no-skills skips it.

    Validation runs first (app exists and matches --app-id, every device exists and is unleased);
    nothing is leased if it fails. All results are returned, including failures; exit 1 means at
    least one failed. --out writes the same JSON incrementally, so an interrupted run still
    records the leases it took. Companion products may be built when missing or changed; the
    supplied app is never built.
    device selects one successful manifest entry and proves ownership with its lease.
    down releases every successful entry through env down, without forcing another lease.
    repo is `amoo agent install` (guided in a terminal) for when you only want the AI client setup.
    Treat manifests as private credentials. For recording, release CLI leases first, then
    use MCP start_session with the same device_hint/build_path; end_session exports the plan.
    """
}

/// Runs each device through `env up` in turn. `onProgress` narrates for a terminal; the manifest is
/// rewritten after every device so a killed run never leaves leases that nothing records.
func runInit(
    _ options: InitOptions,
    setup: (EnvUpOptions) async -> CLIResult = { await runEnvUp($0) },
    onProgress: ((String) -> Void)? = nil
) async -> CLIResult {
    var results: [EnvUpReport] = []
    let app = EnvAppReport(
        id: options.environment.appID,
        path: options.environment.appPath,
        sha256: options.environment.appSHA256 ?? options.environment.appPath.flatMap { sha256Hex(ofPath: $0) },
        installed: false,
        launched: false
    )
    var manifest = InitManifest(ok: true, results: [])
    func persist() {
        guard let out = options.out else { return }
        do { try manifest.write(out) } catch {
            manifest.error = "Cannot write manifest: \(error). Use the returned leases for cleanup."
        }
    }
    // Sequential setup lets env up see each preceding lease/port and keeps companion builds serialized.
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
        if report.app == nil {
            report.app = app
        }
        results.append(report)
        manifest.results = results
        manifest.ok = results.allSatisfy(\.ok)
        persist()
        onProgress?(report.ok
            ? "\(step) Ready: lease \(report.lease ?? "?"), port \(report.port.map(String.init) ?? "?")"
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
        guard let lease = entry.lease else {
            results.append(EnvDownReport(
                ok: false,
                device: entry.device?.id,
                holderStopped: false,
                shutdown: false,
                error: "Successful manifest entry has no lease."
            ))
            continue
        }
        let result = await cleanup(EnvDownOptions(lease: lease, shutdown: shutdown, json: true))
        results.append((try? JSONDecoder().decode(EnvDownReport.self, from: Data(result.output.utf8)))
            ?? EnvDownReport(ok: false, lease: lease, holderStopped: false, shutdown: false, error: result.output))
    }
    let ok = results.allSatisfy(\.ok)
    return CLIResult(output: renderJSON(InitDownReport(ok: ok, results: results)), exitCode: ok ? 0 : 1)
}

private struct InitDownReport: Encodable {
    var ok: Bool
    var results: [EnvDownReport]
}

func initDeviceArguments(_ manifest: InitManifest, device: String, args: [String]) throws -> [String] {
    guard let entry = manifest.results.first(where: { $0.ok && $0.device?.id == device }),
          let lease = entry.lease, let port = entry.port
    else { throw EnvCommandParseError.usage("No successful init entry for device \(device).") }
    // Leading routing flags cannot override the entry's ownership or transport.
    guard !args.contains(where: { ["--lease", "--port", "--platform", "--device"].contains($0) }) else {
        throw EnvCommandParseError.usage("Manifest supplies platform, device, port and lease.")
    }
    return ["--platform", entry.platform, "--device", device, "--port", String(port), "--lease", lease] + args
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
        guard let index = args.firstIndex(of: "--manifest"), args.indices.contains(index + 1) else {
            throw EnvCommandParseError.usage("--manifest <path> is required.")
        }
        let manifest = try InitManifest.read(args[index + 1])
        args.removeSubrange(index ... index + 1)
        if remaining.first == "down" {
            var flags = EnvFlagReader(args)
            let shutdown = flags.take("--shutdown")
            let json = flags.take("--json")
            try flags.finish()
            let result = await runInitDown(manifest, shutdown: shutdown)
            return json ? result : CLIResult(
                output: result.exitCode == 0 ? "Released initialized environments." : result.output,
                exitCode: result.exitCode
            )
        }
        guard let index = args.firstIndex(of: "--device"), args.indices.contains(index + 1) else {
            throw EnvCommandParseError.usage("--device <id> is required.")
        }
        let device = args[index + 1]
        args.removeSubrange(index ... index + 1)
        return try await CLIApp().run(args: ["device"] + initDeviceArguments(manifest, device: device, args: args))
    } catch {
        return CLIResult(output: "\(error)\n\n" + renderInitHelp(), exitCode: 64)
    }
}
