// swiftlint:disable multiline_arguments
import Foundation
import Instrumentation

/// A 16-byte OpenTelemetry trace identifier.
public struct TraceID: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// Creates an identifier from exactly 16 bytes that are not all zero; otherwise `nil`.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 16, bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = bytes
    }

    /// Parses 32 lowercase or uppercase hex characters.
    public init?(hex: some StringProtocol) {
        guard hex.count == 32, let bytes = HexCoding.decode(hex) else { return nil }
        self.init(bytes: bytes)
    }

    public static func random() -> Self {
        var generator = SystemRandomNumberGenerator()
        while true {
            let bytes = (0 ..< 16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            if let id = Self(bytes: bytes) {
                return id
            }
        }
    }

    public var hex: String {
        HexCoding.encode(bytes)
    }

    public var description: String {
        hex
    }
}

/// An 8-byte OpenTelemetry span identifier.
public struct SpanID: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// Creates an identifier from exactly 8 bytes that are not all zero; otherwise `nil`.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 8, bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = bytes
    }

    /// Parses 16 lowercase or uppercase hex characters.
    public init?(hex: some StringProtocol) {
        guard hex.count == 16, let bytes = HexCoding.decode(hex) else { return nil }
        self.init(bytes: bytes)
    }

    public static func random() -> Self {
        var generator = SystemRandomNumberGenerator()
        while true {
            let bytes = (0 ..< 8).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            if let id = Self(bytes: bytes) {
                return id
            }
        }
    }

    public var hex: String {
        HexCoding.encode(bytes)
    }

    public var description: String {
        hex
    }
}

/// The W3C Trace Context identity of one span, carried through `InstrumentationContext`.
public struct SpanContext: Hashable, Sendable {
    public let traceID: TraceID
    public let spanID: SpanID
    /// W3C trace flags; bit 0 is `sampled`.
    public let traceFlags: UInt8
    /// Vendor-specific W3C `tracestate`, propagated unchanged.
    public let traceState: String?
    /// True when this context arrived from another process (a `traceparent` header or variable).
    public let isRemote: Bool

    public init(traceID: TraceID, spanID: SpanID, traceFlags: UInt8 = 1, traceState: String? = nil, isRemote: Bool) {
        self.traceID = traceID
        self.spanID = spanID
        self.traceFlags = traceFlags
        self.traceState = traceState
        self.isRemote = isRemote
    }

    public var isSampled: Bool {
        traceFlags & 1 == 1
    }

    /// The `traceparent` header value (version 00).
    public var traceparent: String {
        "00-\(traceID.hex)-\(spanID.hex)-\(HexCoding.encode([traceFlags]))"
    }

    /// Parses a W3C `traceparent` value; returns `nil` for malformed or all-zero identifiers.
    public init?(traceparent: String, traceState: String? = nil) {
        let parts = traceparent.trimmingCharacters(in: .whitespaces).split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard parts.count >= 4, parts[0].count == 2, parts[0] != "ff",
              HexCoding.decode(parts[0]) != nil,
              parts[0] != "00" || parts.count == 4,
              let traceID = TraceID(hex: parts[1]), let spanID = SpanID(hex: parts[2]),
              parts[3].count == 2, let flags = HexCoding.decode(parts[3])?.first
        else { return nil }
        self.init(
            traceID: traceID, spanID: spanID, traceFlags: flags,
            traceState: traceState?.isEmpty == false ? traceState : nil, isRemote: true
        )
    }
}

/// Stores the active `SpanContext` inside an `InstrumentationContext`.
public enum SpanContextKey: InstrumentationContextKey {
    public typealias Value = SpanContext
    public static let nameOverride: String? = "otel-span-context"
}

public extension InstrumentationContext {
    /// The OpenTelemetry span context of the current span, if any.
    var spanContext: SpanContext? {
        get { self[SpanContextKey.self] }
        set { self[SpanContextKey.self] = newValue }
    }
}

enum HexCoding {
    private static let digits = Array("0123456789abcdef".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(bytes: output, encoding: .ascii) ?? ""
    }

    static func decode(_ hex: some StringProtocol) -> [UInt8]? {
        let characters = Array(hex.utf8)
        guard characters.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = value(characters[index]), let low = value(characters[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func value(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

// swiftlint:enable multiline_arguments
