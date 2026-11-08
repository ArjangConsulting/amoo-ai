@testable import AmooTelemetry
import Foundation
import OTLP
import TestCommons
import Tracing
import XCTest

/// Collects exported spans in memory.
actor RecordingExporter: SpanExporter {
    nonisolated let name = "recording"
    private(set) var spans: [SpanRecord] = []
    private(set) var shutdownCount = 0

    func export(_ spans: [SpanRecord], resource _: TelemetryResource) async throws {
        self.spans.append(contentsOf: spans)
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

final class AmooTelemetryTests: XCTestCase {
    private let resource = TelemetryResource(attributes: ["service.name": .string("amoo")], scopeVersion: "test")

    func testTraceparentRoundTripsAndRejectsMalformedValues() throws {
        let header = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        let context = try XCTUnwrap(SpanContext(traceparent: header))
        XCTAssertEqual(context.traceparent, header)
        XCTAssertTrue(context.isSampled)
        XCTAssertTrue(context.isRemote)

        XCTAssertNil(SpanContext(traceparent: "00-00000000000000000000000000000000-00f067aa0ba902b7-01"))
        XCTAssertNil(SpanContext(traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"))
        XCTAssertNil(SpanContext(traceparent: "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"))
        XCTAssertNil(SpanContext(traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra"))
        XCTAssertNil(SpanContext(traceparent: "garbage"))
    }

    func testChildSpansShareTraceAndPointAtTheirParent() async throws {
        let exporter = RecordingExporter()
        let (tracer, processor) = AmooTelemetry.makeTracer(exporters: [exporter], resource: resource)
        tracer.withSpan("parent", ofKind: .server) { parent in
            parent.attributes["amoo.run.id"] = "run"
            tracer.withSpan("child") { _ in }
        }
        await processor.flush()
        let spans = await exporter.spans
        let parent = try XCTUnwrap(spans.first { $0.name == "parent" })
        let child = try XCTUnwrap(spans.first { $0.name == "child" })
        XCTAssertEqual(child.context.traceID, parent.context.traceID)
        XCTAssertEqual(child.parentSpanID, parent.context.spanID)
        XCTAssertNil(parent.parentSpanID)
        XCTAssertEqual(parent.kind, .server)
        XCTAssertEqual(parent.attributes["amoo.run.id"], .string("run"))
    }

    func testInheritedParentJoinsTheCallersTrace() async throws {
        let exporter = RecordingExporter()
        let inherited =
            try XCTUnwrap(SpanContext(traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"))
        let (tracer, processor) = AmooTelemetry.makeTracer(
            exporters: [exporter], resource: resource, defaultParent: inherited
        )
        tracer.withSpan("root") { _ in }
        await processor.flush()
        let spans = await exporter.spans
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.context.traceID, inherited.traceID)
        XCTAssertEqual(span.parentSpanID, inherited.spanID)
        XCTAssertTrue(span.parentIsRemote)
    }

    func testInjectAndExtractUseW3CHeaders() {
        let (tracer, _) = AmooTelemetry.makeTracer(exporters: [], resource: resource)
        let span = tracer.startSpan("rpc", ofKind: .client)
        var headers: [String: String] = [:]
        tracer.inject(span.context, into: &headers, using: DictionaryCarrier())
        XCTAssertEqual(headers["traceparent"], span.spanContext.traceparent)

        var extracted = InstrumentationContext.topLevel
        tracer.extract(
            ["TRACEPARENT": span.spanContext.traceparent],
            into: &extracted,
            using: DictionaryCarrier(uppercased: true)
        )
        XCTAssertEqual(extracted.spanContext?.spanID, span.spanContext.spanID)
        span.end()
    }

    func testErrorsRecordExceptionEventAndStatus() async throws {
        struct Failure: Error {}
        let exporter = RecordingExporter()
        let (tracer, processor) = AmooTelemetry.makeTracer(exporters: [exporter], resource: resource)
        XCTAssertThrowsError(try tracer.withSpan("failing") { _ in throw Failure() })
        await processor.flush()
        let spans = await exporter.spans
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.events.first?.name, "exception")
        XCTAssertEqual(span.status, .error(message: nil))
    }

    func testOTLPJSONUsesHexIdentifiersAndIntegerEnumsAndRoundTrips() async throws {
        let exporter = RecordingExporter()
        let (tracer, processor) = AmooTelemetry.makeTracer(exporters: [exporter], resource: resource)
        tracer.withSpan("tools/call tap", ofKind: .server) { span in
            span.attributes["amoo.response.bytes"] = 42
        }
        await processor.flush()
        let spans = await exporter.spans
        let record = try XCTUnwrap(spans.first)
        let data = try OTLPEncoding.json(OTLPEncoding.request([record], resource: resource))
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"traceId\":\"\(record.context.traceID.hex)\""), text)
        XCTAssertTrue(text.contains("\"spanId\":\"\(record.context.spanID.hex)\""), text)
        XCTAssertTrue(text.contains("\"kind\":2"), text)

        let decoded = try OTLPEncoding.decodeJSON(data)
        let decodedSpan = try XCTUnwrap(decoded.resourceSpans.first?.scopeSpans.first?.spans.first)
        XCTAssertEqual([UInt8](decodedSpan.traceID), record.context.traceID.bytes)
        XCTAssertEqual(decodedSpan.name, "tools/call tap")
        XCTAssertEqual(decodedSpan.attributes.first?.value.intValue, 42)
    }

    func testFileExporterAppendsOneJSONLinePerBatchChunk() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let directory = scratch.url.appending(path: "telemetry")
        let exporter = OTLPFileExporter(directory: directory)
        let (tracer, processor) = AmooTelemetry.makeTracer(exporters: [exporter], resource: resource)
        for index in 0 ..< (OTLPFileExporter.spansPerLine + 1) {
            tracer.withSpan("span-\(index)") { _ in }
        }
        await processor.shutdown()
        let file = directory.appending(path: OTLPFileExporter.fileName(for: Date()))
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let total = try lines.map { try OTLPEncoding.decodeJSON(Data($0.utf8)) }
            .flatMap(\.resourceSpans).flatMap(\.scopeSpans).flatMap(\.spans).count
        XCTAssertEqual(total, OTLPFileExporter.spansPerLine + 1)
    }

    func testQueueDropsSpansBeyondItsLimit() async {
        let exporter = RecordingExporter()
        var limits = SpanBatchProcessor.Limits()
        limits.maxQueueSize = 2
        limits.maxExportBatchSize = 10
        limits.scheduleDelay = .seconds(60)
        let (tracer, processor) = AmooTelemetry.makeTracer(exporters: [exporter], resource: resource, limits: limits)
        for _ in 0 ..< 5 {
            tracer.withSpan("span") { _ in }
        }
        XCTAssertEqual(processor.droppedSpans, 3)
        await processor.shutdown()
        let exported = await exporter.spans.count
        let shutdowns = await exporter.shutdownCount
        XCTAssertEqual(exported, 2)
        XCTAssertEqual(shutdowns, 1)
    }

    func testConfigurationReadsStandardEnvironment() {
        let local = URL(fileURLWithPath: "/tmp/amoo-telemetry")
        let config = TelemetryConfiguration.fromEnvironment(
            [
                "OTEL_SERVICE_NAME": "amoo-ci",
                "OTEL_RESOURCE_ATTRIBUTES": "team=mobile,ci.run%20id=12",
                "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318",
                "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
                "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer%20token",
                "OTEL_TRACES_EXPORTER": "otlp,console",
                "TRACEPARENT": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
            ],
            serviceVersion: "1.0.0",
            localDirectory: local
        )
        XCTAssertEqual(config.serviceName, "amoo-ci")
        XCTAssertEqual(config.resourceAttributes, ["team": "mobile", "ci.run id": "12"])
        XCTAssertEqual(config.otlpEndpoint?.absoluteString, "http://collector:4318")
        XCTAssertFalse(config.otlpEndpointIsSignalSpecific)
        XCTAssertEqual(config.otlpProtocol, .httpJSON)
        XCTAssertEqual(config.otlpHeaders["Authorization"], "Bearer token")
        XCTAssertTrue(config.console)
        XCTAssertEqual(config.localDirectory, local)
        XCTAssertNotNil(config.inheritedParent)

        let quiet = TelemetryConfiguration.fromEnvironment(
            ["AMOO_TELEMETRY_LOCAL": "0"], serviceVersion: "1", localDirectory: local
        )
        XCTAssertNil(quiet.otlpEndpoint)
        XCTAssertNil(quiet.localDirectory)
        XCTAssertFalse(quiet.console)
        XCTAssertNil(AmooTelemetry.makeTracer(quiet))

        let disabled = TelemetryConfiguration.fromEnvironment(
            ["OTEL_SDK_DISABLED": "true"], serviceVersion: "1", localDirectory: local
        )
        XCTAssertNil(AmooTelemetry.makeTracer(disabled))
    }
}
