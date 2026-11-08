import Foundation

extension UsageReport {
    /// Rule-based next steps from the measured data; each names the number that triggered it.
    mutating func computeRecommendations() {
        var notes: [String] = []
        let inline = tools.reduce(0) { $0 + $1.inlineImages }
        let saved = tools.reduce(0) { $0 + $1.savedImages }
        if inline > 0 {
            let share = Double(inline) / Double(max(1, inline + saved))
            notes.append("\(inline) screenshots returned inline (\(Self.percent(share)) of captures); "
                + "save them with return_image=false and read the file only when pixels are needed.")
        }
        if let tokens, tokens.amooCarriedTokens > 0, let top = tokens.byTool.first {
            let total = Self.compact(tokens.amooCarriedTokens)
            notes.append("\(top.tool) results were re-read as \(Self.compact(top.carriedTokens)) context tokens "
                + "(of \(total) for all amoo results); smaller results there save the most.")
        }
        let calls = tools.reduce(0) { $0 + $1.calls }
        let compact = tools.reduce(0) { $0 + $1.compactCalls }
        if calls > 20, compact * 4 < calls {
            notes.append("Only \(compact) of \(calls) calls used response_mode=compact.")
        }
        if let retried = retries.failedThenInspected["tap_element"], retried >= 5 {
            notes.append("\(retried) failed tap_element calls were followed by an inspection call; "
                + "return near-match candidates in the failure so the agent can retry directly.")
        }
        if let top = retries.identicalConsecutive.max(by: { $0.value < $1.value }), top.value >= 5 {
            notes.append("\(top.key) was repeated with identical arguments \(top.value) times back to back.")
        }
        if retries.transportFailures >= 3 {
            notes.append("\(retries.transportFailures) calls failed on a transient companion connection; "
                + "reconnect and retry idempotent reads in the client.")
        }
        if let slow = tools.filter({ $0.calls >= 5 }).max(by: { $0.p50Ms < $1.p50Ms }), slow.p50Ms >= 2000 {
            notes.append("\(slow.tool) has a p50 of \(slow.p50Ms) ms over \(slow.calls) calls.")
        }
        let locale = codegen.warnings["locale_dependent_selector", default: 0]
        if locale > 0 {
            notes.append("\(locale) generated steps select by visible text; prefer accessibility ids for "
                + "locale-independent tests.")
        }
        let unasserted = codegen.warnings["final_mutation_unasserted", default: 0]
        if unasserted > 0 {
            notes.append("\(unasserted) recorded flows end in a change with no assertion after it.")
        }
        recommendations = notes
    }

    // MARK: - Text

    // One linear report layout, section after section.
    // swiftlint:disable:next function_body_length
    func renderText(baseline: Self?) -> String {
        var lines: [String] = []
        lines.append("amoo usage report — \(window.since.map { "since \($0)" } ?? "all recorded data")"
            + (window.runID.map { ", run \($0)" } ?? ""))
        lines.append(
            "Sources: \(sources.sessions) sessions, \(sources.plans) plans, latency from \(sources.latencySource)"
                + " (\(sources.spans) spans in \(sources.traceFiles) files, \(sources.ledgerCalls) ledger calls),"
                + " \(sources.transcriptsWithAmoo)/\(sources.transcripts) transcripts used amoo"
        )
        if let tokens {
            lines.append("")
            lines.append("Tokens (\(tokens.transcripts) transcripts, \(tokens.subagentTranscripts) subagent, "
                + "\(tokens.assistantTurns) turns)")
            lines.append(
                "  input \(Self.compact(tokens.inputTokens))  cache read \(Self.compact(tokens.cacheReadTokens))"
                    + "  cache write \(Self.compact(tokens.cacheCreationTokens))"
                    + "  output \(Self.compact(tokens.outputTokens))"
            )
            lines.append(
                "  amoo results: \(tokens.amooToolResults) added \(Self.compact(tokens.amooResultTokens)) tokens,"
                    + " re-read \(Self.compact(tokens.amooCarriedTokens)); \(tokens.inlineImages) inline images"
                    + " ≈ \(Self.compact(tokens.inlineImageTokensEstimate)) image tokens"
            )
            lines.append(Self.table(
                ["tool", "results", "tokens", "re-read", "images", "img tok"],
                tokens.byTool.prefix(12).map {
                    [
                        $0.tool,
                        "\($0.results)",
                        Self.compact($0.tokens),
                        Self.compact($0.carriedTokens),
                        "\($0.images)",
                        Self.compact($0.imageTokensEstimate)
                    ]
                }
            ))
        }
        lines.append("")
        lines.append("Tools")
        let previous = Dictionary(baseline?.tools.map { ($0.tool, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        lines.append(Self.table(
            ["tool", "calls", "fail", "p50 ms", "p95 ms", "total s", "resp KB", "inline img", "saved img"],
            tools.prefix(20).map { tool in
                let delta = previous[tool.tool].map { " (\(Self.signed(tool.p50Ms - $0.p50Ms)))" } ?? ""
                return [
                    tool.tool,
                    "\(tool.calls)",
                    "\(tool.failures)",
                    "\(tool.p50Ms)\(delta)",
                    "\(tool.p95Ms)",
                    "\(tool.totalMs / 1000)",
                    "\(tool.responseBytes / 1024)",
                    "\(tool.inlineImages)",
                    "\(tool.savedImages)"
                ]
            }
        ))
        if !rpcs.isEmpty {
            lines.append("")
            lines.append("Companion RPCs")
            lines.append(Self.table(
                ["method", "calls", "fail", "p50 ms", "p95 ms", "device p50", "overhead p50"],
                rpcs.prefix(15).map {
                    [
                        $0.method,
                        "\($0.calls)",
                        "\($0.failures)",
                        "\($0.p50Ms)",
                        "\($0.p95Ms)",
                        $0.serverP50Ms.map(String.init) ?? "-",
                        $0.overheadP50Ms.map(String.init) ?? "-"
                    ]
                }
            ))
        }
        if !phases.isEmpty || !processes.isEmpty {
            lines.append("")
            lines.append("Phases and subprocesses")
            lines.append(Self.table(
                ["name", "count", "p50 ms", "p95 ms", "total s"],
                phases.map { [$0.phase, "\($0.count)", "\($0.p50Ms)", "\($0.p95Ms)", "\($0.totalMs / 1000)"] }
                    + processes.prefix(10).map {
                        ["exec \($0.command)", "\($0.calls)", "\($0.p50Ms)", "\($0.p95Ms)", "\($0.totalMs / 1000)"]
                    }
            ))
        }
        lines.append("")
        lines.append("Retries (\(retries.sessions) sessions): selector misses \(retries.selectorMisses),"
            + " transport failures \(retries.transportFailures), timeouts \(retries.timeouts),"
            + " startups \(retries.startupAttempts) (\(retries.failedStartups) failed)")
        lines.append("  identical back-to-back: \(Self.top(retries.identicalConsecutive))")
        lines.append("  failure → inspection: \(Self.top(retries.failedThenInspected))")
        lines.append("  failure → same tool again: \(Self.top(retries.failedThenRetried))")
        if !errors.isEmpty {
            lines.append("  top errors:")
            lines += errors.prefix(8).map { "    \($0.count)× \($0.tool): \($0.message)" }
        }
        lines.append("")
        lines.append(
            "Generated tests: \(codegen.plans) plans (\(codegen.plansWithSteps) with steps, \(codegen.steps) steps),"
                + " \(codegen.riskPerPlan) risk warnings per plan"
        )
        lines.append("  \(Self.top(codegen.warnings, limit: 8))")
        if !recommendations.isEmpty {
            lines.append("")
            lines.append("Opportunities")
            lines += recommendations.map { "  • \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    static func table(_ header: [String], _ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "  (none)" }
        let all = [header] + rows
        let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
        return all.map { row in
            "  " + row.enumerated().map { index, cell in
                index == 0 ? cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: widths[index] - cell.count) + cell
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    static func top(_ counts: [String: Int], limit: Int = 5) -> String {
        let items = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit)
        return items.isEmpty ? "none" : items.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    static func compact(_ value: Int) -> String {
        switch abs(value) {
        case 1_000_000_000...: String(format: "%.1fB", Double(value) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1e6)
        case 10000...: String(format: "%.0fk", Double(value) / 1e3)
        default: "\(value)"
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
