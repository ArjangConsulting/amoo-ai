// swiftlint:disable multiline_arguments
import Foundation
import Synchronization
import Tracing

/// An immutable, finished span: the unit every exporter receives.
public struct SpanRecord: Sendable {
    public struct Event: Sendable {
        public let name: String
        public let timeUnixNano: UInt64
        public let attributes: [String: TelemetryValue]
    }

    public struct Link: Sendable {
        public let context: SpanContext
        public let attributes: [String: TelemetryValue]
    }

    public enum Status: Sendable, Equatable {
        case unset
        case ok
        case error(message: String?)
    }

    public let name: String
    public let kind: SpanKind
    public let context: SpanContext
    public let parentSpanID: SpanID?
    public let parentIsRemote: Bool
    public let startTimeUnixNano: UInt64
    public let endTimeUnixNano: UInt64
    public let attributes: [String: TelemetryValue]
    public let droppedAttributes: Int
    public let events: [Event]
    public let droppedEvents: Int
    public let links: [Link]
    public let status: Status

    public var durationNanoseconds: UInt64 {
        endTimeUnixNano >= startTimeUnixNano ? endTimeUnixNano - startTimeUnixNano : 0
    }
}

/// A sendable attribute value in OpenTelemetry's primitive and homogeneous-array types.
public enum TelemetryValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case stringArray([String])
    case boolArray([Bool])
    case intArray([Int64])
    case doubleArray([Double])

    // One case per swift-distributed-tracing attribute type.
    // swiftlint:disable:next cyclomatic_complexity
    init?(_ attribute: SpanAttribute) {
        switch attribute {
        case let .int32(value): self = .int(Int64(value))
        case let .int64(value): self = .int(value)
        case let .int32Array(value): self = .intArray(value.map(Int64.init))
        case let .int64Array(value): self = .intArray(value)
        case let .double(value): self = .double(value)
        case let .doubleArray(value): self = .doubleArray(value)
        case let .bool(value): self = .bool(value)
        case let .boolArray(value): self = .boolArray(value)
        case let .string(value): self = .string(value)
        case let .stringArray(value): self = .stringArray(value)
        case let .stringConvertible(value): self = .string(value.description)
        case let .stringConvertibleArray(value): self = .stringArray(value.map(\.description))
        default: return nil
        }
    }

    /// The attribute as an integer when it holds one (used by local readers).
    public var intValue: Int64? {
        if case let .int(value) = self {
            value
        } else {
            nil
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }
}

/// The span type `AmooTracer` hands out. Thread-safe; ending it twice is a no-op.
public final class AmooSpan: Tracing.Span, Sendable {
    /// OpenTelemetry SDK default span limits.
    static let attributeLimit = 128
    static let eventLimit = 128
    static let linkLimit = 128
    static let valueLengthLimit = 4096

    private struct State {
        var operationName: String
        var attributes = SpanAttributes()
        var events: [SpanRecord.Event] = []
        var droppedEvents = 0
        var links: [SpanRecord.Link] = []
        var status: SpanRecord.Status = .unset
        var ended = false
    }

    public let context: InstrumentationContext
    public let spanContext: SpanContext
    let kind: SpanKind
    let parent: SpanContext?
    let startTimeUnixNano: UInt64
    private let state: Mutex<State>
    private let onEnd: @Sendable (SpanRecord) -> Void

    init(
        operationName: String,
        kind: SpanKind,
        context: InstrumentationContext,
        spanContext: SpanContext,
        parent: SpanContext?,
        startTimeUnixNano: UInt64,
        onEnd: @escaping @Sendable (SpanRecord) -> Void
    ) {
        self.context = context
        self.spanContext = spanContext
        self.kind = kind
        self.parent = parent
        self.startTimeUnixNano = startTimeUnixNano
        state = Mutex(State(operationName: operationName))
        self.onEnd = onEnd
    }

    public var operationName: String {
        get { state.withLock { $0.operationName } }
        set { state.withLock {
            if !$0.ended {
                $0.operationName = newValue
            }
        } }
    }

    public var attributes: SpanAttributes {
        get { state.withLock { $0.attributes } }
        set { state.withLock {
            if !$0.ended {
                $0.attributes = newValue
            }
        } }
    }

    public var isRecording: Bool {
        state.withLock { !$0.ended }
    }

    public func setStatus(_ status: SpanStatus) {
        state.withLock { current in
            guard !current.ended else { return }
            switch status.code {
            case .ok:
                current.status = .ok
            case .error:
                // Ok is final per the specification; error never downgrades it.
                if current.status != .ok {
                    current.status = .error(message: status.message)
                }
            }
        }
    }

    public func addEvent(_ event: SpanEvent) {
        let converted = SpanRecord.Event(
            name: event.name, timeUnixNano: event.nanosecondsSinceEpoch,
            attributes: Self.convert(event.attributes).values
        )
        state.withLock { current in
            guard !current.ended else { return }
            if current.events.count < Self.eventLimit {
                current.events.append(converted)
            } else {
                current.droppedEvents += 1
            }
        }
    }

    public func recordError(
        _ error: any Error,
        attributes: SpanAttributes,
        at instant: @autoclosure () -> some TracerInstant
    ) {
        var eventAttributes = attributes
        eventAttributes.set("exception.type", value: .string(String(reflecting: type(of: error))))
        eventAttributes.set("exception.message", value: .string(String(describing: error)))
        addEvent(SpanEvent(name: "exception", at: instant(), attributes: eventAttributes))
    }

    public func addLink(_ link: SpanLink) {
        guard let linked = link.context.spanContext else { return }
        let converted = SpanRecord.Link(context: linked, attributes: Self.convert(link.attributes).values)
        state.withLock { current in
            if !current.ended, current.links.count < Self.linkLimit {
                current.links.append(converted)
            }
        }
    }

    public func end(at instant: @autoclosure () -> some TracerInstant) {
        let endTime = instant().nanosecondsSinceEpoch
        let finished: State? = state.withLock { current in
            guard !current.ended else { return nil }
            current.ended = true
            return current
        }
        guard let finished else { return }
        let converted = Self.convert(finished.attributes)
        onEnd(SpanRecord(
            name: finished.operationName,
            kind: kind,
            context: spanContext,
            parentSpanID: parent?.spanID,
            parentIsRemote: parent?.isRemote ?? false,
            startTimeUnixNano: startTimeUnixNano,
            endTimeUnixNano: max(endTime, startTimeUnixNano),
            attributes: converted.values,
            droppedAttributes: converted.dropped,
            events: finished.events,
            droppedEvents: finished.droppedEvents,
            links: finished.links,
            status: finished.status
        ))
    }

    static func convert(_ attributes: SpanAttributes) -> (values: [String: TelemetryValue], dropped: Int) {
        var values: [String: TelemetryValue] = [:]
        var dropped = 0
        // SpanAttributes only offers forEach; it is not a Sequence.
        // swiftformat:disable:next preferForLoop
        attributes.forEach { key, attribute in
            guard values.count < attributeLimit, let value = TelemetryValue(attribute) else {
                dropped += 1
                return
            }
            values[key] = truncated(value)
        }
        return (values, dropped)
    }

    private static func truncated(_ value: TelemetryValue) -> TelemetryValue {
        switch value {
        case let .string(text) where text.count > valueLengthLimit:
            .string(String(text.prefix(valueLengthLimit)))
        case let .stringArray(texts):
            .stringArray(texts.map { $0.count > valueLengthLimit ? String($0.prefix(valueLengthLimit)) : $0 })
        default:
            value
        }
    }
}

// swiftlint:enable multiline_arguments
