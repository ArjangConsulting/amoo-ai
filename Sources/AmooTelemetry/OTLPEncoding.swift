import Foundation
import OTLP
import SwiftProtobuf
import Tracing

/// Converts finished spans into OTLP messages and the OTLP/JSON wire form.
///
/// OTLP/JSON is proto3 JSON with three deviations this type applies: trace and span ids are
/// lowercase hex (not base64), enums are integers, and keys use lowerCamelCase field names.
public enum OTLPEncoding {
    public static func request(
        _ spans: [SpanRecord],
        resource: TelemetryResource
    ) -> Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest {
        var scope = Opentelemetry_Proto_Common_V1_InstrumentationScope()
        scope.name = resource.scopeName
        scope.version = resource.scopeVersion
        var scopeSpans = Opentelemetry_Proto_Trace_V1_ScopeSpans()
        scopeSpans.scope = scope
        scopeSpans.spans = spans.map(span)
        var otlpResource = Opentelemetry_Proto_Resource_V1_Resource()
        otlpResource.attributes = keyValues(resource.attributes)
        var resourceSpans = Opentelemetry_Proto_Trace_V1_ResourceSpans()
        resourceSpans.resource = otlpResource
        resourceSpans.scopeSpans = [scopeSpans]
        var request = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest()
        request.resourceSpans = [resourceSpans]
        return request
    }

    /// One compact OTLP/JSON object (an `ExportTraceServiceRequest`, which is the same shape as
    /// `TracesData`), suitable for `http/json` bodies and JSON-lines files.
    public static func json(
        _ request: Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest
    ) throws -> Data {
        var options = JSONEncodingOptions()
        options.alwaysPrintEnumsAsInts = true
        options.preserveProtoFieldNames = false
        let canonical = try request.jsonUTF8Data(options: options)
        let object = try JSONSerialization.jsonObject(with: canonical)
        return try JSONSerialization.data(withJSONObject: hexIdentifiers(object), options: [.sortedKeys])
    }

    /// Parses one OTLP/JSON object back into a request (accepts hex ids as written by ``json(_:)``).
    public static func decodeJSON(
        _ data: Data
    ) throws -> Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest {
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(withJSONObject: base64Identifiers(object))
        var options = JSONDecodingOptions()
        options.ignoreUnknownFields = true
        return try .init(jsonUTF8Data: canonical, options: options)
    }

    static func span(_ record: SpanRecord) -> Opentelemetry_Proto_Trace_V1_Span {
        var span = Opentelemetry_Proto_Trace_V1_Span()
        span.traceID = Data(record.context.traceID.bytes)
        span.spanID = Data(record.context.spanID.bytes)
        span.traceState = record.context.traceState ?? ""
        if let parent = record.parentSpanID {
            span.parentSpanID = Data(parent.bytes)
        }
        span.flags = UInt32(record.context.traceFlags) | 0x100 | (record.parentIsRemote ? 0x200 : 0)
        span.name = record.name
        span.kind = kind(record.kind)
        span.startTimeUnixNano = record.startTimeUnixNano
        span.endTimeUnixNano = record.endTimeUnixNano
        span.attributes = keyValues(record.attributes)
        span.droppedAttributesCount = UInt32(clamping: record.droppedAttributes)
        span.events = record.events.map { event in
            var converted = Opentelemetry_Proto_Trace_V1_Span.Event()
            converted.name = event.name
            converted.timeUnixNano = event.timeUnixNano
            converted.attributes = keyValues(event.attributes)
            return converted
        }
        span.droppedEventsCount = UInt32(clamping: record.droppedEvents)
        span.links = record.links.map { link in
            var converted = Opentelemetry_Proto_Trace_V1_Span.Link()
            converted.traceID = Data(link.context.traceID.bytes)
            converted.spanID = Data(link.context.spanID.bytes)
            converted.traceState = link.context.traceState ?? ""
            converted.attributes = keyValues(link.attributes)
            converted.flags = UInt32(link.context.traceFlags) | 0x100 | (link.context.isRemote ? 0x200 : 0)
            return converted
        }
        var status = Opentelemetry_Proto_Trace_V1_Status()
        switch record.status {
        case .unset:
            status.code = .unset
        case .ok:
            status.code = .ok
        case let .error(message):
            status.code = .error
            status.message = message ?? ""
        }
        span.status = status
        return span
    }

    static func kind(_ kind: SpanKind) -> Opentelemetry_Proto_Trace_V1_Span.SpanKind {
        switch kind {
        case .server: .server
        case .client: .client
        case .producer: .producer
        case .consumer: .consumer
        case .internal: .internal
        }
    }

    static func keyValues(_ attributes: [String: TelemetryValue]) -> [Opentelemetry_Proto_Common_V1_KeyValue] {
        attributes.keys.sorted().compactMap { key in
            guard let value = attributes[key] else { return nil }
            var pair = Opentelemetry_Proto_Common_V1_KeyValue()
            pair.key = key
            pair.value = anyValue(value)
            return pair
        }
    }

    static func anyValue(_ value: TelemetryValue) -> Opentelemetry_Proto_Common_V1_AnyValue {
        var any = Opentelemetry_Proto_Common_V1_AnyValue()
        switch value {
        case let .string(text): any.stringValue = text
        case let .bool(flag): any.boolValue = flag
        case let .int(number): any.intValue = number
        case let .double(number): any.doubleValue = number
        case let .stringArray(values): any.arrayValue = array(values.map(TelemetryValue.string))
        case let .boolArray(values): any.arrayValue = array(values.map(TelemetryValue.bool))
        case let .intArray(values): any.arrayValue = array(values.map(TelemetryValue.int))
        case let .doubleArray(values): any.arrayValue = array(values.map(TelemetryValue.double))
        }
        return any
    }

    private static func array(_ values: [TelemetryValue]) -> Opentelemetry_Proto_Common_V1_ArrayValue {
        var array = Opentelemetry_Proto_Common_V1_ArrayValue()
        array.values = values.map(anyValue)
        return array
    }

    private static let identifierKeys: Set<String> = ["traceId", "spanId", "parentSpanId"]

    private static func hexIdentifiers(_ object: Any) -> Any {
        rewriteIdentifiers(object) { base64 in
            Data(base64Encoded: base64).map { HexCoding.encode([UInt8]($0)) } ?? base64
        }
    }

    private static func base64Identifiers(_ object: Any) -> Any {
        rewriteIdentifiers(object) { hex in
            HexCoding.decode(hex).map { Data($0).base64EncodedString() } ?? hex
        }
    }

    private static func rewriteIdentifiers(_ object: Any, _ transform: (String) -> String) -> Any {
        if let dictionary = object as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, value) in dictionary {
                if identifierKeys.contains(key), let text = value as? String {
                    output[key] = transform(text)
                } else {
                    output[key] = rewriteIdentifiers(value, transform)
                }
            }
            return output
        }
        if let array = object as? [Any] {
            return array.map { rewriteIdentifiers($0, transform) }
        }
        return object
    }
}
