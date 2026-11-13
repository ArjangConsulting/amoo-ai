// swiftlint:disable multiline_arguments
import AmooTelemetry
import Foundation
import OTLP

/// A decoded span, reduced to what the report aggregates.
struct UsageSpan: Equatable {
    var traceID: String
    var name: String
    var startUnixNano: UInt64
    var durationMs: Int
    var failed: Bool
    var attributes: [String: String]

    func int(_ key: String) -> Int {
        attributes[key].flatMap { Int($0) ?? Double($0).map { Int($0) } } ?? 0
    }
}

enum UsageTraceReader {
    /// Reads every OTLP/JSON line in `directory` from files whose UTC day is on or after `since`.
    static func read(directory: URL, since: Date?) -> (spans: [UsageSpan], files: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return ([], 0) }
        let cutoffName = since.map { OTLPFileExporter.fileName(for: $0) }
        let selected = files.filter { file in
            file.lastPathComponent.hasPrefix("traces-") && file.pathExtension == "jsonl"
                && cutoffName.map { file.lastPathComponent >= $0 } ?? true
        }
        let sinceNano = since.map { UInt64(max(0, $0.timeIntervalSince1970) * 1e9) } ?? 0
        var spans: [UsageSpan] = []
        for file in selected {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let request = try? OTLPEncoding.decodeJSON(Data(line.utf8)) else { continue }
                for resource in request.resourceSpans {
                    for scope in resource.scopeSpans {
                        for span in scope.spans where span.startTimeUnixNano >= sinceNano {
                            spans.append(convert(span))
                        }
                    }
                }
            }
        }
        return (spans, selected.count)
    }

    static func convert(_ span: Opentelemetry_Proto_Trace_V1_Span) -> UsageSpan {
        var attributes: [String: String] = [:]
        for pair in span.attributes {
            switch pair.value.value {
            case let .stringValue(text): attributes[pair.key] = text
            case let .intValue(number): attributes[pair.key] = String(number)
            case let .doubleValue(number): attributes[pair.key] = String(number)
            case let .boolValue(flag): attributes[pair.key] = String(flag)
            default: break
            }
        }
        let duration = span.endTimeUnixNano > span.startTimeUnixNano
            ? span.endTimeUnixNano - span.startTimeUnixNano : 0
        return UsageSpan(
            traceID: span.traceID.map { String(format: "%02x", $0) }.joined(),
            name: span.name,
            startUnixNano: span.startTimeUnixNano,
            durationMs: Int(duration / 1_000_000),
            failed: span.status.code == .error,
            attributes: attributes
        )
    }

    /// Keeps the spans of traces that contain a tool call for `runID`.
    static func filter(_ spans: [UsageSpan], runID: String?) -> [UsageSpan] {
        guard let runID else { return spans }
        let traces = Set(spans.filter { $0.attributes[TelemetryAttribute.runID] == runID }.map(\.traceID))
        return spans.filter { traces.contains($0.traceID) }
    }

    /// RPC, subprocess and phase breakdowns (tool rows come from ``ToolSample/aggregate(_:)``).
    static func aggregate(_ spans: [UsageSpan], into report: inout UsageReport) {
        report.rpcs = rpcUsage(spans)
        report.processes = processUsage(spans)
        let phaseNames: Set = [
            "session_bootstrap", "companion.ensure", "app.install", "app.launch", "screen.ready",
            "device_queue.wait", "hierarchy.read"
        ]
        let phases = Dictionary(grouping: spans.filter { phaseNames.contains($0.name) }, by: \.name)
        report.phases = phases.map { name, group in
            let durations = group.map(\.durationMs)
            return UsageReport.PhaseUsage(
                phase: name, count: group.count,
                p50Ms: UsageStatistics.percentile(durations, 0.5),
                p95Ms: UsageStatistics.percentile(durations, 0.95),
                totalMs: durations.reduce(0, +)
            )
        }.sorted { $0.totalMs > $1.totalMs }
    }

    /// One sample per `execute_tool` span.
    static func toolSamples(_ spans: [UsageSpan]) -> [ToolSample] {
        spans.filter { $0.name.hasPrefix("execute_tool ") }.map { span in
            let inline = span.attributes[TelemetryAttribute.imageInline] == "true"
            return ToolSample(
                tool: span.attributes[TelemetryAttribute.genAIToolName] ?? "?",
                callID: span.attributes[TelemetryAttribute.callID],
                milliseconds: span.durationMs,
                failed: span.failed,
                errorCode: span.attributes[TelemetryAttribute.errorType],
                responseBytes: span.int(TelemetryAttribute.responseBytes),
                textBytes: span.int(TelemetryAttribute.responseTextBytes),
                inlineImageBytes: inline ? span.int(TelemetryAttribute.imageBytes) : 0,
                inlineImagePixels: inline
                    ? span.int(TelemetryAttribute.imageWidth) * span.int(TelemetryAttribute.imageHeight) : 0,
                inlineImage: inline,
                savedImage: !inline && span.attributes[TelemetryAttribute.imageBytes] != nil,
                repeated: span.attributes[TelemetryAttribute.repeatedCall] == "true",
                compact: span.attributes[TelemetryAttribute.responseMode] != "full",
                surface: span.attributes[TelemetryAttribute.client] ?? "unknown"
            )
        }
    }

    private static func rpcUsage(_ spans: [UsageSpan]) -> [UsageReport.RPCUsage] {
        let rpcs = spans.filter { $0.attributes[TelemetryAttribute.rpcSystem] == "grpc" }
        return Dictionary(grouping: rpcs) { $0.attributes[TelemetryAttribute.rpcMethod] ?? $0.name }
            .map { method, group in
                let durations = group.map(\.durationMs)
                let server = group.compactMap { span in
                    span.attributes[TelemetryAttribute.companionServerMilliseconds].flatMap(Double.init).map(Int.init)
                }
                let overhead = group.compactMap { span -> Int? in
                    guard let raw = span.attributes[TelemetryAttribute.companionServerMilliseconds],
                          let serverMs = Double(raw) else { return nil }
                    return max(0, span.durationMs - Int(serverMs))
                }
                return UsageReport.RPCUsage(
                    method: method, calls: group.count, failures: group.count { $0.failed },
                    p50Ms: UsageStatistics.percentile(durations, 0.5),
                    p95Ms: UsageStatistics.percentile(durations, 0.95),
                    serverP50Ms: server.isEmpty ? nil : UsageStatistics.percentile(server, 0.5),
                    overheadP50Ms: overhead.isEmpty ? nil : UsageStatistics.percentile(overhead, 0.5)
                )
            }
            .sorted { $0.p50Ms * $0.calls > $1.p50Ms * $1.calls }
    }

    private static func processUsage(_ spans: [UsageSpan]) -> [UsageReport.ProcessUsage] {
        let processes = spans.filter { $0.name.hasPrefix("exec ") }
        return Dictionary(grouping: processes) { span in
            [
                span.attributes[TelemetryAttribute.processExecutableName],
                span.attributes[TelemetryAttribute.processSubcommand]
            ]
            .compactMap(\.self).joined(separator: " ")
        }
        .map { command, group in
            let durations = group.map(\.durationMs)
            return UsageReport.ProcessUsage(
                command: command, calls: group.count, failures: group.count { $0.failed },
                p50Ms: UsageStatistics.percentile(durations, 0.5),
                p95Ms: UsageStatistics.percentile(durations, 0.95),
                totalMs: durations.reduce(0, +)
            )
        }
        .sorted { $0.totalMs > $1.totalMs }
    }
}

/// The per-call run ledger (`sessions/runs/<run>/<call>.json`), used when no spans cover the
/// window — every amoo version since run telemetry shipped wrote it.
enum UsageLedgerReader {
    struct Entry: Decodable {
        let runID: String
        let callID: String?
        let tool: String
        let startedAt: String
        let status: String
        let metrics: [String: Int]
        let errorCode: String?
    }

    static func read(directory: URL, since: Date?, runID: String?) -> [Entry] {
        let runs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var entries: [Entry] = []
        let parser = ISO8601DateFormatter()
        for run in runs where runID == nil || run.lastPathComponent == runID {
            let calls = (try? FileManager.default.contentsOfDirectory(at: run, includingPropertiesForKeys: nil)) ?? []
            for call in calls where call.pathExtension == "json" {
                guard let data = try? Data(contentsOf: call),
                      let entry = try? JSONDecoder().decode(Entry.self, from: data) else { continue }
                if let since, let started = parser.date(from: entry.startedAt), started < since {
                    continue
                }
                entries.append(entry)
            }
        }
        return entries
    }

    static func samples(_ entries: [Entry]) -> [ToolSample] {
        entries.map { entry in
            let imageBytes = entry.metrics["image_bytes", default: 0]
            return ToolSample(
                tool: entry.tool,
                callID: entry.callID,
                milliseconds: entry.metrics["elapsed_ms", default: 0],
                failed: entry.status == "failed",
                errorCode: entry.errorCode,
                responseBytes: entry.metrics["wire_response_bytes", default: 0],
                textBytes: entry.metrics["text_payload_bytes", default: 0],
                inlineImageBytes: imageBytes,
                inlineImagePixels: imageBytes > 0 ? entry.metrics["image_pixels", default: 0] : 0,
                inlineImage: imageBytes > 0,
                savedImage: entry.metrics["evidence_image_bytes", default: 0] > 0,
                repeated: false,
                compact: false,
                surface: "unknown"
            )
        }
    }
}

/// One tool call from either source, so spans and older ledger entries aggregate together.
struct ToolSample {
    var tool: String
    var callID: String?
    var milliseconds: Int
    var failed: Bool
    var errorCode: String?
    var responseBytes: Int
    var textBytes: Int
    var inlineImageBytes: Int
    var inlineImagePixels: Int
    var inlineImage: Bool
    var savedImage: Bool
    var repeated: Bool
    var compact: Bool
    var surface: String

    static func aggregate(_ samples: [Self]) -> [UsageReport.ToolUsage] {
        Dictionary(grouping: samples, by: \.tool).map { tool, group in
            var usage = UsageReport.ToolUsage(tool: tool)
            let durations = group.map(\.milliseconds)
            usage.calls = group.count
            usage.failures = group.count { $0.failed }
            usage.p50Ms = UsageStatistics.percentile(durations, 0.5)
            usage.p95Ms = UsageStatistics.percentile(durations, 0.95)
            usage.maxMs = durations.max() ?? 0
            usage.totalMs = durations.reduce(0, +)
            for sample in group {
                usage.responseBytes += sample.responseBytes
                usage.textBytes += sample.textBytes
                usage.inlineImages += sample.inlineImage ? 1 : 0
                usage.inlineImageBytes += sample.inlineImageBytes
                usage.inlineImagePixels += sample.inlineImagePixels
                usage.savedImages += sample.savedImage ? 1 : 0
                usage.repeatedCalls += sample.repeated ? 1 : 0
                usage.compactCalls += sample.compact ? 1 : 0
                usage.surfaces[sample.surface, default: 0] += 1
                if sample.failed {
                    // An entry older than the code field still counts, as a cause nobody recorded.
                    usage.failureCauses = (usage.failureCauses ?? [:])
                        .merging([sample.errorCode ?? "unrecorded": 1], uniquingKeysWith: +)
                }
            }
            return usage
        }.sorted { $0.totalMs > $1.totalMs }
    }
}

// swiftlint:enable multiline_arguments
