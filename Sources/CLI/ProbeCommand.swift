import AmooCore
import Foundation
import MCP
import ProcessRunner
import WebInspector

// MARK: - Options

/// `amoo probe run`: evaluates checked-in JavaScript probes inside the app's WebView and judges
/// each by its `{probe, pass, details}` result, writing one evidence file per probe.
struct ProbeRunOptions: Equatable {
    var files: [String] = []
    var platform: Platform = .ios
    var deviceID: String?
    var lease: String?
    var bundleID: String?
    var timeoutMilliseconds = 30000
    /// Exit 1 when any probe reports `pass: false`.
    var expectPass = false
    /// Stop after the first probe that does not pass.
    var bail = false
    var evidenceDir: String?
    var json = false
}

func renderProbeHelp() -> String {
    """
    Usage: amoo probe run <probe.js>... --platform ios|android --device <id>
                          [--lease <id>] [--bundle-id <id>] [--timeout-ms <n>]
                          [--expect-pass] [--bail] [--evidence-dir <dir>] [--json]

    Each probe is a JavaScript expression (typically an IIFE, sync or async) that returns
    {probe, pass, details} — as an object or a JSON string. Probes run in order in the app's
    inspectable WebView; promises are awaited.

      --expect-pass   exit 1 when any probe reports pass=false
      --bail          stop at the first probe that does not pass
      --evidence-dir  write <dir>/<probe-file>.json per probe (raw value, parsed result, timing)

    Exit codes: 0 ok, 1 a probe failed (--expect-pass), 2 a probe could not run (tooling),
    3 device leased by another session.
    """
}

func parseProbeRunOptions(args: [String]) -> Result<ProbeRunOptions, EnvCommandParseError> {
    var flags = EnvFlagReader(args)
    var options = ProbeRunOptions()
    do {
        guard let platform = try flags.value("--platform").flatMap({ Platform(rawValue: $0.lowercased()) }) else {
            throw EnvCommandParseError.usage("probe run needs --platform ios|android.")
        }
        options.platform = platform
        options.deviceID = try flags.value("--device")
        options.lease = try flags.value("--lease")
        options.bundleID = try flags.value("--bundle-id")
        options.timeoutMilliseconds = try flags.int("--timeout-ms") ?? options.timeoutMilliseconds
        options.expectPass = flags.take("--expect-pass")
        options.bail = flags.take("--bail")
        options.evidenceDir = try flags.value("--evidence-dir")
        options.json = flags.take("--json")
        options.files = flags.remainingPositionals()
        try flags.finish()
    } catch let error as EnvCommandParseError {
        return .failure(error)
    } catch {
        return .failure(.usage("\(error)"))
    }
    guard options.deviceID != nil else { return .failure(.usage("probe run needs --device <id>.")) }
    guard !options.files.isEmpty else { return .failure(.usage("probe run needs at least one probe file.")) }
    return .success(options)
}

extension EnvFlagReader {
    /// Removes and returns every token that is not a `--flag`, in order.
    mutating func remainingPositionals() -> [String] {
        var positionals: [String] = []
        while let index = firstPositionalIndex() {
            positionals.append(removeToken(at: index))
        }
        return positionals
    }
}

// MARK: - Results

struct ProbeResult: Encodable, Equatable {
    enum Status: String, Encodable { case pass, fail, error }

    var probe: String
    var file: String
    var status: Status
    var details: Value?
    var error: String?
    var durationMs: Int
    var evidence: String?

    enum CodingKeys: String, CodingKey {
        case probe, file, status, details, error, evidence
        case durationMs = "duration_ms"
    }
}

struct ProbeRunReport: Encodable {
    var ok: Bool
    var platform: String
    var device: String?
    var bundleID: String?
    var results: [ProbeResult]
    var passed: Int
    var failed: Int
    var errors: Int
    var amooVersion = AmooBuildInfo.current.version
    var amooCommit = AmooBuildInfo.current.sourceCommit

    enum CodingKeys: String, CodingKey {
        case ok, platform, device, results, passed, failed, errors
        case bundleID = "bundle_id"
        case amooVersion = "amoo_version"
        case amooCommit = "amoo_commit"
    }
}

struct ProbeInterpretation: Equatable {
    var name: String
    /// `nil` when the value has no boolean `pass`.
    var pass: Bool?
    var details: Value?
}

/// Reads a probe's return value: an object, or a JSON string holding one.
func interpretProbeValue(_ jsonValue: String, fallbackName: String) -> ProbeInterpretation {
    guard var object = try? JSONSerialization.jsonObject(with: Data(jsonValue.utf8), options: .fragmentsAllowed)
    else { return ProbeInterpretation(name: fallbackName) }
    if let text = object as? String,
       let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) {
        object = inner
    }
    guard let dictionary = object as? [String: Any] else { return ProbeInterpretation(name: fallbackName) }
    let details = dictionary["details"].flatMap { value -> Value? in
        guard let data = try? JSONSerialization.data(withJSONObject: ["v": value]) else { return nil }
        return (try? JSONDecoder().decode([String: Value].self, from: data))?["v"]
    }
    return ProbeInterpretation(
        name: dictionary["probe"] as? String ?? fallbackName,
        pass: dictionary["pass"] as? Bool,
        details: details
    )
}

// MARK: - Run

func runProbeCommand(
    _ options: ProbeRunOptions,
    inspector: any WebInspecting = makeWebInspecting(processRunner: SystemProcessRunner())
) async -> CLIResult {
    do {
        try enforceLease(deviceID: options.deviceID, lease: presentedLease(flag: options.lease))
    } catch {
        return CLIResult(output: "\(error)", exitCode: 3)
    }
    var report = ProbeRunReport(
        ok: false,
        platform: options.platform.rawValue,
        device: options.deviceID,
        bundleID: options.bundleID,
        results: [],
        passed: 0,
        failed: 0,
        errors: 0
    )
    let platform = WebInspectorPlatform(rawValue: options.platform.rawValue) ?? .ios
    let client: (any WebInspectorClient)?
    let connectError: String?
    do {
        client = try await inspector.client(platform: platform, bundleID: options.bundleID, deviceID: options.deviceID)
        connectError = nil
    } catch {
        client = nil
        connectError = (error as? WebInspectorError)?.description ?? "\(error)"
    }

    for file in options.files {
        let result = await runProbe(file: file, client: client, connectError: connectError, options: options)
        report.results.append(result)
        if options.bail, result.status != .pass {
            break
        }
    }
    await client?.close()

    report.passed = report.results.count { $0.status == .pass }
    report.failed = report.results.count { $0.status == .fail }
    report.errors = report.results.count { $0.status == .error }
    report.ok = report.errors == 0 && (report.failed == 0 || !options.expectPass)
    let exitCode: Int32 = report.errors > 0 ? 2 : (options.expectPass && report.failed > 0 ? 1 : 0)
    return CLIResult(output: options.json ? renderJSON(report) : humanProbeSummary(report), exitCode: exitCode)
}

private func runProbe(
    file: String,
    client: (any WebInspectorClient)?,
    connectError: String?,
    options: ProbeRunOptions
) async -> ProbeResult {
    let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    var result = ProbeResult(probe: name, file: file, status: .error, durationMs: 0)
    guard let client else {
        result.error = connectError
        return result
    }
    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
        result.error = "Cannot read \(file)."
        return result
    }

    let start = Date()
    var raw: WebViewEvalResult?
    do {
        raw = try await client.evaluate(WebViewEvalRequest(
            expression: source,
            bundleID: options.bundleID,
            timeoutMilliseconds: options.timeoutMilliseconds
        ))
    } catch {
        result.error = (error as? WebInspectorError)?.description ?? "\(error)"
    }
    result.durationMs = Int(Date().timeIntervalSince(start) * 1000)

    if let raw {
        if raw.isException {
            result.error = "Probe threw: \(raw.jsonValue)"
        } else {
            let parsed = interpretProbeValue(raw.jsonValue, fallbackName: name)
            result.probe = parsed.name
            result.details = parsed.details
            if let pass = parsed.pass {
                result.status = pass ? .pass : .fail
            } else {
                result.error = "Probe did not return {pass: boolean}: \(raw.jsonValue.prefix(300))"
            }
        }
    }
    result.evidence = writeProbeEvidence(result, source: source, raw: raw, options: options, startedAt: start)
    return result
}

private struct ProbeEvidence: Encodable {
    var result: ProbeResult
    var platform: String
    var device: String?
    var bundleID: String?
    var startedAt: Date
    var rawValue: String?
    var frameURL: String?
    var sourceSHA256: String

    enum CodingKeys: String, CodingKey {
        case result, platform, device
        case bundleID = "bundle_id"
        case startedAt = "started_at"
        case rawValue = "raw_value"
        case frameURL = "frame_url"
        case sourceSHA256 = "source_sha256"
    }
}

private func writeProbeEvidence(
    _ result: ProbeResult,
    source: String,
    raw: WebViewEvalResult?,
    options: ProbeRunOptions,
    startedAt: Date
) -> String? {
    guard let directory = options.evidenceDir else { return nil }
    let url = URL(fileURLWithPath: directory)
        .appendingPathComponent(URL(fileURLWithPath: result.file).lastPathComponent + ".json")
    let evidence = ProbeEvidence(
        result: result,
        platform: options.platform.rawValue,
        device: options.deviceID,
        bundleID: options.bundleID,
        startedAt: startedAt,
        rawValue: raw?.jsonValue,
        frameURL: raw?.frameURL,
        sourceSHA256: sha256Hex(Data(source.utf8))
    )
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(renderJSON(evidence).utf8).write(to: url)
        return url.path
    } catch {
        return nil
    }
}

private func humanProbeSummary(_ report: ProbeRunReport) -> String {
    let lines = report.results.map { result in
        let tag = result.status.rawValue.uppercased()
        let suffix = result.error.map { " — \($0)" } ?? ""
        return "\(tag)  \(result.probe) (\(result.durationMs) ms)\(suffix)"
    }
    return (lines + ["\(report.passed) passed, \(report.failed) failed, \(report.errors) errors"])
        .joined(separator: "\n")
}

func handleProbeCommand(remaining: [String]) async -> CLIResult {
    guard remaining.first == "run", !isHelpRequest(remaining) else {
        return CLIResult(output: renderProbeHelp(), exitCode: isHelpRequest(remaining) ? 0 : 64)
    }
    switch parseProbeRunOptions(args: Array(remaining.dropFirst())) {
    case let .failure(.usage(message)):
        return CLIResult(output: message + "\n\n" + renderProbeHelp(), exitCode: 64)
    case let .success(options):
        return await runProbeCommand(options)
    }
}
