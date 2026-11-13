// swiftlint:disable line_length
import AmooTelemetry
@testable import CLI
import Foundation
import TestCommons
import XCTest

final class UsageReportTests: XCTestCase {
    func testSinceAcceptsISOTimesDatesAndRelativeAges() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UsageReportOptions.parseSince("7d", now: now), now.addingTimeInterval(-7 * 86400))
        XCTAssertEqual(UsageReportOptions.parseSince("12h", now: now), now.addingTimeInterval(-12 * 3600))
        XCTAssertEqual(
            UsageReportOptions.parseSince("2026-11-01T00:00:00Z", now: now),
            Date(timeIntervalSince1970: 1_793_491_200)
        )
        XCTAssertNotNil(UsageReportOptions.parseSince("2026-11-01", now: now))
        XCTAssertNil(UsageReportOptions.parseSince("soon", now: now))
        XCTAssertThrowsError(try UsageReportOptions.parse(["--since", "soon"]))
        XCTAssertThrowsError(try UsageReportOptions.parse(["--run-id", "not-a-uuid"]))
    }

    func testShellCommandsCountOnlyAmooInCommandPosition() {
        XCTAssertEqual(
            UsageTranscriptReader.cliCommand(".build/debug/amoo device --platform ios tap_element"),
            "device tap_element"
        )
        XCTAssertEqual(UsageTranscriptReader.cliCommand("cd repo && amoo env up --platform ios"), "env up")
        XCTAssertEqual(UsageTranscriptReader.cliCommand("export A=$(.build/debug/amoo env list --json)"), "env list")
        XCTAssertEqual(UsageTranscriptReader.cliCommand("/opt/homebrew/bin/amoo --version; shasum x"), "--version")
        XCTAssertNil(UsageTranscriptReader.cliCommand("swift build --product amoo 2>&1 | tail"))
        XCTAssertNil(UsageTranscriptReader.cliCommand("ls -la .build/debug/amoo"))
        XCTAssertNil(UsageTranscriptReader.cliCommand("git commit -m \"Fix\n amoo does not crash\""))
        XCTAssertNil(UsageTranscriptReader.cliCommand("cat > a.sh <<'EOF'\namoo device tap\nEOF"))
        XCTAssertEqual(
            UsageTranscriptReader.amooTool(name: "mcp__amoo-debug__take_screenshot", input: nil),
            "take_screenshot"
        )
        XCTAssertEqual(UsageTranscriptReader.amooTool(name: "mcp__plugin_amoo_amoo__tap", input: nil), "tap")
        XCTAssertNil(UsageTranscriptReader.amooTool(name: "mcp__github__get_issue", input: nil))
    }

    func testImageHeadersAndTokenEstimate() throws {
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        png += [0, 0, 0x01, 0x92, 0, 0, 0x03, 0x6A]
        let dimensions = try XCTUnwrap(ImageHeader.dimensions(base64: Data(png).base64EncodedString()))
        XCTAssertEqual(dimensions.width, 402)
        XCTAssertEqual(dimensions.height, 874)

        let jpeg: [UInt8] = [
            0xFF,
            0xD8,
            0xFF,
            0xE0,
            0x00,
            0x04,
            0x00,
            0x00,
            0xFF,
            0xC0,
            0x00,
            0x11,
            0x08,
            0x03,
            0x6A,
            0x01,
            0x92,
            0x03
        ]
        let jpegSize = try XCTUnwrap(ImageHeader.dimensions(data: jpeg))
        XCTAssertEqual(jpegSize.width, 402)
        XCTAssertEqual(jpegSize.height, 874)

        XCTAssertEqual(UsageStatistics.imageTokens(width: 402, height: 874), 468)
        // A full-resolution 3x phone screenshot is capped by the client's downscaling.
        XCTAssertLessThanOrEqual(UsageStatistics.imageTokens(width: 1206, height: 2622), 1534)
        XCTAssertGreaterThan(UsageStatistics.imageTokens(width: 1206, height: 2622), 1400)
    }

    func testTranscriptAttributesMeasuredContextGrowthAndReReads() throws {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-11-07T10:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":50},"content":[{"type":"tool_use","id":"t1","name":"mcp__amoo__take_screenshot","input":{}},{"type":"tool_use","id":"t2","name":"Read","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"Screenshot captured"}]},{"type":"tool_result","tool_use_id":"t2","content":"x"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-07T10:00:05.000Z","message":{"id":"m2","usage":{"input_tokens":10,"cache_read_input_tokens":1050,"cache_creation_input_tokens":600,"output_tokens":5},"content":[]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-07T10:00:09.000Z","message":{"id":"m3","usage":{"input_tokens":10,"cache_read_input_tokens":1700,"cache_creation_input_tokens":0,"output_tokens":5},"content":[]}}"#
        ]
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let file = scratch.url.appending(path: "session.jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: file)

        var report = UsageReport(generatedAt: "now", window: .init(), sources: .init())
        UsageTranscriptReader.aggregate(files: [file], since: nil, into: &report)
        let tokens = try XCTUnwrap(report.tokens)
        XCTAssertEqual(tokens.transcripts, 1)
        XCTAssertEqual(tokens.assistantTurns, 3)
        XCTAssertEqual(tokens.outputTokens, 60)
        XCTAssertEqual(tokens.amooToolResults, 1)
        // Context grew by 1660 − 1010 − 50 = 600, shared by size between the two results.
        let screenshot = try XCTUnwrap(tokens.byTool.first { $0.tool == "take_screenshot" })
        XCTAssertEqual(screenshot.results, 1)
        XCTAssertGreaterThan(screenshot.tokens, 400)
        XCTAssertLessThanOrEqual(screenshot.tokens, 600)
        XCTAssertEqual(screenshot.carriedTokens, screenshot.tokens * 2)
    }

    func testSessionsCountRetriesAndPlansClassifyWarnings() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let session = scratch.url.appending(path: "4485C5C4-1072-4702-B8EE-714F25630B4A")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let action: (String, Bool, String) -> String = { tool, error, result in
            #"{"timestamp":"2026-11-07T10:00:00.000Z","toolName":"\#(tool)","arguments":{"label":"Go"},"result":"\#(result)","isError":\#(error),"intent":"testStep","observedElements":[]}"#
        }
        let actions = [
            action("tap_element", true, "tap_element failed: no element matched the selector"),
            action("find_elements", false, "ok"),
            action("tap_element", false, "ok"),
            action("swipe", false, "ok"),
            action("swipe", false, "ok")
        ].joined(separator: ",")
        let report = #"{"sessionID":"4485C5C4-1072-4702-B8EE-714F25630B4A","appID":"a","deviceID":"d","platform":"ios","startedAt":"2026-11-07T10:00:00.000Z","durationSeconds":1,"actionCount":5,"errorCount":1,"isActive":false,"actions":[\#(actions)],"launchArguments":[],"launchEnvironment":{}}"#
        try Data(report.utf8).write(to: session.appending(path: "report.json"))
        let plan = #"{"steps":[{}],"compiledPlan":{"warnings":[{"reason":"Visible-copy selector depends on locale; prefer an id"},{"reason":"Final mutation has no following semantic assertion"},{"category":"inspection_omitted","reason":"inspection-only tool"}]}}"#
        try Data(plan.utf8).write(to: session.appending(path: "plan.json"))

        let options = try UsageReportOptions.parse([
            "--sessions-dir", scratch.url.path, "--telemetry-dir", scratch.url.appending(path: "none").path,
            "--transcripts", "none"
        ])
        let built = await buildUsageReport(options)
        XCTAssertEqual(built.sources.sessions, 1)
        XCTAssertEqual(built.retries.selectorMisses, 1)
        XCTAssertEqual(built.retries.failedThenInspected["tap_element"], 1)
        XCTAssertEqual(built.retries.failedThenRetried["tap_element"], 1)
        XCTAssertEqual(built.retries.identicalConsecutive["swipe"], 1)
        XCTAssertEqual(built.codegen.warnings["locale_dependent_selector"], 1)
        XCTAssertEqual(built.codegen.warnings["final_mutation_unasserted"], 1)
        XCTAssertEqual(built.codegen.warnings["inspection_omitted"], 1)
        XCTAssertEqual(built.codegen.riskPerPlan, 2)
        XCTAssertTrue(built.renderText(baseline: nil).contains("Generated tests: 1 plans"))
    }

    func testFailuresAreBrokenDownByCauseIncludingEntriesWithoutACode() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let run = scratch.url.appending(path: "runs/0037D5F4-3285-49E2-AC8F-65924E4C8105")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let calls = [
            ("a", "failed", #","errorCode":"startup_failed""#), ("b", "failed", #","errorCode":"startup_failed""#),
            ("c", "failed", #","errorCode":"invalid_argument""#), ("d", "failed", ""), ("e", "completed", "")
        ]
        for (call, status, code) in calls {
            let entry = #"{"runID":"0037D5F4-3285-49E2-AC8F-65924E4C8105","callID":"\#(call)","tool":"start_session","#
                + #""startedAt":"2026-11-07T10:00:00Z","status":"\#(status)","metrics":{"elapsed_ms":40}\#(code)}"#
            try Data(entry.utf8).write(to: run.appending(path: "\(call).json"))
        }
        let options = try UsageReportOptions.parse([
            "--sessions-dir", scratch.url.path, "--telemetry-dir", scratch.url.appending(path: "none").path,
            "--transcripts", "none"
        ])

        let report = await buildUsageReport(options)

        let tool = try XCTUnwrap(report.tools.first { $0.tool == "start_session" })
        XCTAssertEqual(tool.failures, 4)
        XCTAssertEqual(tool.failureCauses, ["startup_failed": 2, "invalid_argument": 1, "unrecorded": 1])
        let text = report.renderText(baseline: nil)
        XCTAssertTrue(text.contains("Failure causes"), text)
        XCTAssertTrue(text.contains("start_session: startup_failed 2, invalid_argument 1, unrecorded 1"), text)
    }

    func testSpansAndLedgerMergeWithoutDoubleCounting() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let telemetry = scratch.url.appending(path: "telemetry")
        let exporter = OTLPFileExporter(directory: telemetry)
        let (tracer, processor) = AmooTelemetry.makeTracer(
            exporters: [exporter], resource: TelemetryResource(attributes: [:], scopeVersion: "test")
        )
        tracer.withSpan("execute_tool tap") { span in
            span.attributes[TelemetryAttribute.genAIToolName] = "tap"
            span.attributes[TelemetryAttribute.callID] = "covered"
            span.attributes[TelemetryAttribute.client] = "mcp"
            tracer.withSpan("amoo.CompanionService/Tap", ofKind: .client) { rpc in
                rpc.attributes[TelemetryAttribute.rpcSystem] = "grpc"
                rpc.attributes[TelemetryAttribute.rpcMethod] = "Tap"
                rpc.attributes[TelemetryAttribute.companionServerMilliseconds] = 0.0
            }
        }
        await processor.shutdown()
        let run = scratch.url.appending(path: "runs/0037D5F4-3285-49E2-AC8F-65924E4C8105")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        for (call, tool) in [("covered", "tap"), ("older", "tap"), ("startup", "start_session")] {
            let entry = #"{"runID":"0037D5F4-3285-49E2-AC8F-65924E4C8105","callID":"\#(call)","tool":"\#(tool)","startedAt":"2026-11-07T10:00:00Z","status":"completed","metrics":{"elapsed_ms":40}}"#
            try Data(entry.utf8).write(to: run.appending(path: "\(call).json"))
        }
        let options = try UsageReportOptions.parse([
            "--sessions-dir", scratch.url.path, "--telemetry-dir", telemetry.path, "--transcripts", "none"
        ])
        let report = await buildUsageReport(options)
        XCTAssertEqual(report.sources.latencySource, "spans+run-ledger")
        XCTAssertEqual(report.tools.first { $0.tool == "tap" }?.calls, 2)
        XCTAssertEqual(report.tools.first { $0.tool == "tap" }?.surfaces["mcp"], 1)
        XCTAssertEqual(report.retries.startupAttempts, 1)
        XCTAssertEqual(report.rpcs.first?.method, "Tap")
        XCTAssertEqual(report.rpcs.first?.serverP50Ms, 0)
    }
}

// swiftlint:enable line_length
