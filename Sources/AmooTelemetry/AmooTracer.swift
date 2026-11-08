import Foundation
import Instrumentation
import Tracing

/// OpenTelemetry tracer for amoo, conforming to swift-distributed-tracing's `Tracer`.
///
/// Libraries instrument with the standard `withSpan` API and stay unaware of this type; the
/// executable bootstraps it once through ``AmooTelemetry/bootstrap(_:)``. It propagates W3C
/// `traceparent`/`tracestate` and hands finished spans to a ``SpanBatchProcessor``.
public struct AmooTracer: Tracer {
    public typealias Span = AmooSpan

    let processor: SpanBatchProcessor
    /// A process-wide parent (for example a `TRACEPARENT` supplied by the invoking agent) used
    /// when a span starts without an active span context.
    let defaultParent: SpanContext?

    // The parameter list is fixed by swift-distributed-tracing's `Tracer` requirement.
    // swiftlint:disable:next function_parameter_count
    public func startSpan(
        _ operationName: String,
        context: @autoclosure () -> InstrumentationContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> some TracerInstant,
        function _: String,
        file _: String,
        line _: UInt
    ) -> AmooSpan {
        var spanContextHolder = context()
        let parent = spanContextHolder.spanContext ?? defaultParent
        let spanContext = SpanContext(
            traceID: parent?.traceID ?? .random(),
            spanID: .random(),
            traceFlags: parent?.traceFlags ?? 1,
            traceState: parent?.traceState,
            isRemote: false
        )
        spanContextHolder.spanContext = spanContext
        let processor = processor
        return AmooSpan(
            operationName: operationName,
            kind: kind,
            context: spanContextHolder,
            spanContext: spanContext,
            parent: parent,
            startTimeUnixNano: instant().nanosecondsSinceEpoch,
            onEnd: { record in processor.enqueue(record) }
        )
    }

    public func forceFlush() {
        processor.requestFlush()
    }

    public func extract<Carrier, Extract: Extractor>(
        _ carrier: Carrier,
        into context: inout InstrumentationContext,
        using extractor: Extract
    ) where Extract.Carrier == Carrier {
        guard let header = extractor.extract(key: "traceparent", from: carrier),
              let parent = SpanContext(
                  traceparent: header,
                  traceState: extractor.extract(key: "tracestate", from: carrier)
              )
        else { return }
        context.spanContext = parent
    }

    public func inject<Carrier, Inject: Injector>(
        _ context: InstrumentationContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Inject.Carrier == Carrier {
        guard let spanContext = context.spanContext else { return }
        injector.inject(spanContext.traceparent, forKey: "traceparent", into: &carrier)
        if let state = spanContext.traceState {
            injector.inject(state, forKey: "tracestate", into: &carrier)
        }
    }
}

/// Reads and writes `traceparent`/`tracestate` in a plain string dictionary (environment
/// variables use upper-case `TRACEPARENT`/`TRACESTATE`).
public struct DictionaryCarrier: Extractor, Injector {
    public typealias Carrier = [String: String]
    private let uppercased: Bool

    public init(uppercased: Bool = false) {
        self.uppercased = uppercased
    }

    public func extract(key: String, from carrier: [String: String]) -> String? {
        carrier[uppercased ? key.uppercased() : key]
    }

    public func inject(_ value: String, forKey key: String, into carrier: inout [String: String]) {
        carrier[uppercased ? key.uppercased() : key] = value
    }
}
