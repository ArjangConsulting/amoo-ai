import AmooLogging
import Foundation
import TestSession

func renderUsageHelp() -> String {
    """
    Usage: amoo usage report [options]

    Where agent tokens and time go when driving amoo: tool latency and payload sizes from amoo's
    OpenTelemetry spans (or the run ledger for older data), retry patterns from recorded sessions,
    generated-test warnings from plans, and real token usage from Claude Code transcripts.
    Reads local files only and prints counts, never content.

    Options:
      --since <when>          Only data on or after an ISO-8601 time, or a relative age like 7d or 12h
      --run-id <uuid>         Only one run (spans and ledger entries carrying that run id)
      --transcripts <dir>     Claude Code transcript folder; 'all' for every project, 'none' to skip
                              (default: ~/.claude/projects/<current directory>)
      --sessions-dir <dir>    Session store (default: AMOO_SESSIONS_DIR or the standard location)
      --telemetry-dir <dir>   OTLP/JSON trace files (default: AMOO_TELEMETRY_DIR or <sessions>/telemetry)
      --baseline <file>       A previous --out report; shows p50 changes per tool
      --out <file>            Also write the JSON report to a file (use it as a later baseline)
      --json                  Print JSON instead of text
    """
}

func handleUsageCommand(remaining: [String]) async -> CLIResult {
    guard remaining.first == "report" else {
        return CLIResult(output: renderUsageHelp(), exitCode: isHelpRequest(remaining) ? 0 : 64)
    }
    let args = Array(remaining.dropFirst())
    if isHelpRequest(args) {
        return CLIResult(output: renderUsageHelp(), exitCode: 0)
    }
    do {
        let options = try UsageReportOptions.parse(args)
        let report = await buildUsageReport(options)
        if let out = options.out {
            try Data(renderJSON(report).utf8).write(to: URL(fileURLWithPath: out))
        }
        if options.json {
            return CLIResult(output: renderJSON(report), exitCode: 0)
        }
        let baseline = try options.baseline.map { path in
            try JSONDecoder().decode(UsageReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        return CLIResult(output: report.renderText(baseline: baseline), exitCode: 0)
    } catch let error as EnvCommandParseError {
        return CLIResult(output: "\(error)\n\n\(renderUsageHelp())", exitCode: 64)
    } catch {
        return CLIResult(output: "usage report failed: \(error)", exitCode: 1)
    }
}

struct UsageReportOptions {
    var since: Date?
    var sinceLabel: String?
    var runID: String?
    var transcripts: URL?
    var allTranscripts = false
    var sessionsDirectory: URL
    var telemetryDirectory: URL
    var baseline: String?
    var out: String?
    var json = false

    static func parse(
        _ args: [String],
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        var flags = EnvFlagReader(args)
        let json = flags.take("--json")
        let sinceRaw = try flags.value("--since")
        let runID = try flags.value("--run-id")
        let transcriptsRaw = try flags.value("--transcripts")
        let sessionsRaw = try flags.value("--sessions-dir")
        let telemetryRaw = try flags.value("--telemetry-dir")
        let baseline = try flags.value("--baseline")
        let out = try flags.value("--out")
        try flags.finish()

        let sessions = sessionsRaw.map { URL(fileURLWithPath: $0) } ?? FileSessionStore().root
        var options = Self(
            runID: runID,
            sessionsDirectory: sessions,
            telemetryDirectory: telemetryRaw.map { URL(fileURLWithPath: $0) }
                ?? environment["AMOO_TELEMETRY_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? sessions.appending(path: "telemetry"),
            baseline: baseline,
            out: out,
            json: json
        )
        if let runID, UUID(uuidString: runID) == nil {
            throw EnvCommandParseError.usage("--run-id must be a UUID")
        }
        if let sinceRaw {
            guard let since = parseSince(sinceRaw, now: now) else {
                throw EnvCommandParseError.usage("--since takes an ISO-8601 time or an age like 7d, 12h or 30m")
            }
            options.since = since
            options.sinceLabel = since.ISO8601Format()
        }
        switch transcriptsRaw {
        case "none":
            options.transcripts = nil
        case "all":
            options.allTranscripts = true
            options.transcripts = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        case let path?:
            options.transcripts = URL(fileURLWithPath: path)
        case nil:
            let directory = UsageTranscriptReader.defaultDirectory()
            options.transcripts = FileManager.default.fileExists(atPath: directory.path) ? directory : nil
        }
        return options
    }

    static func parseSince(_ raw: String, now: Date) -> Date? {
        if let date = ISO8601DateFormatter().date(from: raw) {
            return date
        }
        if let day = ISO8601DateFormatter.dateOnly.date(from: raw) {
            return day
        }
        guard let unit = raw.last, let amount = Double(raw.dropLast()), amount >= 0 else { return nil }
        let seconds: Double = switch unit {
        case "d": 86400
        case "h": 3600
        case "m": 60
        default: -1
        }
        return seconds < 0 ? nil : now.addingTimeInterval(-amount * seconds)
    }
}

private extension ISO8601DateFormatter {
    static var dateOnly: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }
}

private let usageLogger = AmooLogger.forType(UsageReport.self)

func buildUsageReport(_ options: UsageReportOptions, now: Date = Date()) async -> UsageReport {
    usageLogger.info(
        "Building usage report",
        context: "since=\(options.sinceLabel ?? "all") run=\(options.runID ?? "all")"
    )
    var report = UsageReport(
        generatedAt: now.ISO8601Format(),
        window: .init(since: options.sinceLabel, runID: options.runID),
        sources: .init()
    )

    let (allSpans, files) = UsageTraceReader.read(directory: options.telemetryDirectory, since: options.since)
    let spans = UsageTraceReader.filter(allSpans, runID: options.runID)
    report.sources.traceFiles = files
    report.sources.spans = spans.count
    let ledger = UsageLedgerReader.read(
        directory: options.sessionsDirectory.appending(path: "runs"), since: options.since, runID: options.runID
    )
    report.sources.ledgerCalls = ledger.count
    // Spans and the run ledger describe the same calls since spans carry the ledger's call id;
    // older ledger entries fill in history from before spans existed.
    let spanSamples = UsageTraceReader.toolSamples(spans)
    let covered = Set(spanSamples.compactMap(\.callID))
    let ledgerSamples = UsageLedgerReader.samples(ledger.filter { $0.callID.map { !covered.contains($0) } ?? true })
    report.sources.latencySource = switch (spanSamples.isEmpty, ledgerSamples.isEmpty) {
    case (false, false): "spans+run-ledger"
    case (false, true): "spans"
    case (true, false): "run-ledger"
    case (true, true): "none"
    }
    report.tools = ToolSample.aggregate(spanSamples + ledgerSamples)
    UsageTraceReader.aggregate(spans, into: &report)
    let startups = ledger.filter { $0.tool == "start_session" }
    report.retries.startupAttempts = startups.count
    report.retries.failedStartups = startups.count { $0.status == "failed" }

    var sessions = await FileSessionStore(root: options.sessionsDirectory).loadAllReports()
    if let since = options.since {
        sessions = sessions.filter { $0.startedAt >= since }
    }
    if let runID = options.runID {
        sessions = sessions.filter { $0.provenance?["run_id"] == runID }
    }
    report.sources.sessions = sessions.count
    UsageSessionReader.aggregate(sessions, into: &report)
    let filtered = options.since != nil || options.runID != nil
    UsageSessionReader.aggregatePlans(
        root: options.sessionsDirectory,
        sessionIDs: filtered ? Set(sessions.map(\.sessionID)) : nil,
        into: &report
    )

    if let transcripts = options.transcripts {
        let files = UsageTranscriptReader.transcriptFiles(in: transcripts)
        UsageTranscriptReader.aggregate(files: files, since: options.since, into: &report)
    }
    report.computeRecommendations()
    usageLogger.info(
        "Built usage report",
        context: "spans=\(report.sources.spans) sessions=\(report.sources.sessions)"
            + " transcripts=\(report.sources.transcripts)"
    )
    return report
}
