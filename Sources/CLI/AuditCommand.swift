import AmooCore
import AuditEngine
import Foundation

public enum AuditFailThreshold: String, Sendable {
    case none
    case info
    case low
    case medium
    case high
    case critical
}

public struct AuditCommandOptions: Sendable, Equatable {
    public var appID: String
    public var screenSummary: String
    public var rootID: String
    public var failOn: AuditFailThreshold
    public var outputJSONPath: String?
    public var outputMarkdownPath: String?

    public init(
        appID: String,
        screenSummary: String,
        rootID: String,
        failOn: AuditFailThreshold,
        outputJSONPath: String?,
        outputMarkdownPath: String?
    ) {
        self.appID = appID
        self.screenSummary = screenSummary
        self.rootID = rootID
        self.failOn = failOn
        self.outputJSONPath = outputJSONPath
        self.outputMarkdownPath = outputMarkdownPath
    }
}

public enum AuditCommandParseError: Error, CustomStringConvertible {
    case usage
    case missingValue(flag: String)
    case missingRequiredFlag(flag: String)
    case invalidFailThreshold(String)
    case unexpectedArgument(String)

    public var description: String {
        switch self {
        case .usage:
            renderAuditHelp()
        case let .missingValue(flag):
            "Missing value for \(flag)."
        case let .missingRequiredFlag(flag):
            "Missing required flag \(flag)."
        case let .invalidFailThreshold(value):
            "Invalid --fail-on value '\(value)'. Expected none, info, low, medium, high, or critical."
        case let .unexpectedArgument(arg):
            "Unexpected argument '\(arg)'."
        }
    }
}

func renderAuditHelp() -> String {
    """
    Usage: amoo audit --app-id <bundle-id> \
    [--screen-summary <text>] [--root-id <id>] \
    [--fail-on none|info|low|medium|high|critical] \
    [--out-json <path>] [--out-md <path>]
    """
}

public protocol AuditRunning: Sendable {
    func runAudit(options: AuditCommandOptions) async throws -> AuditReport
}

public struct DefaultAuditRunner: AuditRunning {
    public init() {}

    public func runAudit(options: AuditCommandOptions) async throws -> AuditReport {
        let engine = AuditEngine(rules: RulePacks.all)
        let input = AuditInput(
            appID: options.appID,
            screenContext: .init(summary: options.screenSummary),
            hierarchy: .init(id: options.rootID)
        )
        return try await engine.run(input)
    }
}

public struct AuditCommandExecution: Sendable, Equatable {
    public var output: String
    public var exitCode: Int32

    public init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }
}

public func parseAuditOptions(args: [String]) throws -> AuditCommandOptions {
    guard !args.isEmpty else {
        throw AuditCommandParseError.usage
    }

    var state = AuditOptionState()
    var index = 0

    while index < args.count {
        let token = args[index]
        let value = try consumeValue(args: args, index: &index, flag: token)
        try applyAuditToken(token, value: value, state: &state)
        index += 2
    }

    guard let appID = state.appID else {
        throw AuditCommandParseError.missingRequiredFlag(flag: "--app-id")
    }

    return AuditCommandOptions(
        appID: appID,
        screenSummary: state.screenSummary,
        rootID: state.rootID,
        failOn: state.failOn,
        outputJSONPath: state.outputJSONPath,
        outputMarkdownPath: state.outputMarkdownPath
    )
}

public func runAuditCommand(
    options: AuditCommandOptions,
    runner: any AuditRunning
) async throws -> AuditCommandExecution {
    let report = try await runner.runAudit(options: options)
    let sortedFindings = sortFindings(report.findings)

    let markdown = renderAuditMarkdown(
        appID: report.appID,
        findings: sortedFindings,
        failOn: options.failOn
    )
    let json = try renderAuditJSON(
        appID: report.appID,
        findings: sortedFindings,
        failOn: options.failOn
    )

    if let jsonPath = options.outputJSONPath {
        try writeFile(path: jsonPath, contents: json)
    }
    if let markdownPath = options.outputMarkdownPath {
        try writeFile(path: markdownPath, contents: markdown)
    }

    var output = markdown
    if options.outputJSONPath != nil || options.outputMarkdownPath != nil {
        var lines = ["Audit artifacts written:"]
        if let jsonPath = options.outputJSONPath {
            lines.append("- JSON: \(jsonPath)")
        }
        if let markdownPath = options.outputMarkdownPath {
            lines.append("- Markdown: \(markdownPath)")
        }
        lines.append("")
        lines.append(markdown)
        output = lines.joined(separator: "\n")
    }

    return AuditCommandExecution(
        output: output,
        exitCode: shouldFailBuild(findings: sortedFindings, threshold: options.failOn) ? 2 : 0
    )
}

private struct AuditOptionState {
    var appID: String?
    var screenSummary = ""
    var rootID = "root"
    var failOn: AuditFailThreshold = .high
    var outputJSONPath: String?
    var outputMarkdownPath: String?
}

private struct AuditSeverityCounts {
    var critical = 0
    var high = 0
    var medium = 0
    var low = 0
    var info = 0
}

private func applyAuditToken(_ token: String, value: String, state: inout AuditOptionState) throws {
    switch token {
    case "--app-id":
        state.appID = value
    case "--screen-summary":
        state.screenSummary = value
    case "--root-id":
        state.rootID = value
    case "--out-json":
        state.outputJSONPath = value
    case "--out-md":
        state.outputMarkdownPath = value
    case "--fail-on":
        guard let parsed = AuditFailThreshold(rawValue: value.lowercased()) else {
            throw AuditCommandParseError.invalidFailThreshold(value)
        }
        state.failOn = parsed
    default:
        throw AuditCommandParseError.unexpectedArgument(token)
    }
}

private func consumeValue(args: [String], index: inout Int, flag: String) throws -> String {
    guard flag.hasPrefix("--") else {
        throw AuditCommandParseError.unexpectedArgument(flag)
    }

    let valueIndex = index + 1
    guard valueIndex < args.count else {
        throw AuditCommandParseError.missingValue(flag: flag)
    }

    let value = args[valueIndex]
    guard !value.hasPrefix("--") else {
        throw AuditCommandParseError.missingValue(flag: flag)
    }

    return value
}

private func severityRank(_ severity: Severity) -> Int {
    switch severity {
    case .critical:
        5
    case .high:
        4
    case .medium:
        3
    case .low:
        2
    case .info:
        1
    }
}

private func thresholdSeverity(_ threshold: AuditFailThreshold) -> Severity? {
    switch threshold {
    case .none:
        nil
    case .info:
        .info
    case .low:
        .low
    case .medium:
        .medium
    case .high:
        .high
    case .critical:
        .critical
    }
}

private func shouldFailBuild(findings: [AuditFinding], threshold: AuditFailThreshold) -> Bool {
    guard let minimum = thresholdSeverity(threshold) else {
        return false
    }

    let minimumRank = severityRank(minimum)
    return findings.contains(where: { severityRank($0.severity) >= minimumRank })
}

private func sortFindings(_ findings: [AuditFinding]) -> [AuditFinding] {
    findings.sorted { lhs, rhs in
        let lhsRank = severityRank(lhs.severity)
        let rhsRank = severityRank(rhs.severity)

        if lhsRank == rhsRank {
            return lhs.id < rhs.id
        }

        return lhsRank > rhsRank
    }
}

private func writeFile(path: String, contents: String) throws {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

private func renderAuditMarkdown(
    appID: String,
    findings: [AuditFinding],
    failOn: AuditFailThreshold
) -> String {
    let generatedAt = ISO8601DateFormatter().string(from: Date())
    let counts = summaryCounts(findings: findings)

    var lines: [String] = []
    lines.append("# Audit Report")
    lines.append("- App ID: `\(appID)`")
    lines.append("- Generated: `\(generatedAt)`")
    lines.append("- Fail Policy: `\(failOn.rawValue)`")
    lines.append("- Total Findings: `\(findings.count)`")
    lines.append("")
    lines.append("## Severity Summary")
    lines.append("- Critical: \(counts.critical)")
    lines.append("- High: \(counts.high)")
    lines.append("- Medium: \(counts.medium)")
    lines.append("- Low: \(counts.low)")
    lines.append("- Info: \(counts.info)")
    lines.append("")

    if findings.isEmpty {
        lines.append("## Findings")
        lines.append("No findings.")
        return lines.joined(separator: "\n")
    }

    lines.append("## Findings")
    for finding in findings {
        lines.append("### [\(finding.severity.rawValue.uppercased())] \(finding.ruleID) - \(finding.summary)")
        lines.append("- ID: `\(finding.id)`")
        lines.append("- Confidence: \(String(format: "%.2f", finding.confidence))")
        lines.append("- Remediation: \(finding.remediation)")
        lines.append("- Tags: \(finding.tags.joined(separator: ", "))")

        if finding.evidence.isEmpty {
            lines.append("- Evidence: none")
        } else {
            lines.append("- Evidence:")
            for evidence in finding.evidence {
                lines.append("  - `\(evidence.kind.rawValue)`: \(evidence.summary) (`\(evidence.sourceRef)`)")
            }
        }

        lines.append("")
    }

    return lines.joined(separator: "\n")
}

private func renderAuditJSON(
    appID: String,
    findings: [AuditFinding],
    failOn: AuditFailThreshold
) throws -> String {
    let generatedAt = ISO8601DateFormatter().string(from: Date())
    let summary = summaryCounts(findings: findings)
    let payload = AuditJSONPayload(
        appID: appID,
        generatedAt: generatedAt,
        policy: .init(failOn: failOn.rawValue),
        summary: .init(
            totalFindings: findings.count,
            critical: summary.critical,
            high: summary.high,
            medium: summary.medium,
            low: summary.low,
            info: summary.info
        ),
        findings: findings.map { finding in
            AuditJSONPayload.Finding(
                id: finding.id,
                ruleID: finding.ruleID,
                severity: finding.severity.rawValue,
                confidence: finding.confidence,
                summary: finding.summary,
                remediation: finding.remediation,
                tags: finding.tags,
                evidence: finding.evidence.map { evidence in
                    AuditJSONPayload.Evidence(
                        kind: evidence.kind.rawValue,
                        summary: evidence.summary,
                        sourceRef: evidence.sourceRef,
                        attributes: evidence.attributes
                    )
                }
            )
        }
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try String(data: encoder.encode(payload), encoding: .utf8) ?? "{}"
}

private func summaryCounts(findings: [AuditFinding]) -> AuditSeverityCounts {
    var counts = AuditSeverityCounts()

    for finding in findings {
        switch finding.severity {
        case .critical:
            counts.critical += 1
        case .high:
            counts.high += 1
        case .medium:
            counts.medium += 1
        case .low:
            counts.low += 1
        case .info:
            counts.info += 1
        }
    }

    return counts
}

private struct AuditJSONPayload: Codable {
    struct Policy: Codable {
        var failOn: String
    }

    struct Summary: Codable {
        var totalFindings: Int
        var critical: Int
        var high: Int
        var medium: Int
        var low: Int
        var info: Int
    }

    struct Evidence: Codable {
        var kind: String
        var summary: String
        var sourceRef: String
        var attributes: [String: String]
    }

    struct Finding: Codable {
        var id: String
        var ruleID: String
        var severity: String
        var confidence: Double
        var summary: String
        var remediation: String
        var tags: [String]
        var evidence: [Evidence]
    }

    var appID: String
    var generatedAt: String
    var policy: Policy
    var summary: Summary
    var findings: [Finding]
}
