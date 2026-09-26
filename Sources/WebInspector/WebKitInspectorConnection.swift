import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One frame-level channel to `webinspectord`: each message is a binary property list preceded by
/// its 4-byte big-endian length. Injectable so the protocol logic is testable without a simulator.
public protocol WebKitRPCChannel: Sendable {
    /// Sends one message: `{"__selector": selector, "__argument": argument}`.
    func send(selector: String, argument: [String: WIRValue]) async throws
    /// The next inbound message; `nil` once the connection has closed. Throws
    /// `WebInspectorError.timedOut` after `timeout` without losing later messages.
    func receive(timeout: Duration) async throws -> WIRMessage?
    func close() async
}

/// A decoded Remote Inspector message.
public struct WIRMessage: Sendable, Equatable {
    public var selector: String
    public var argument: [String: WIRValue]

    public init(selector: String, argument: [String: WIRValue]) {
        self.selector = selector
        self.argument = argument
    }
}

/// The property-list values the Remote Inspector protocol uses.
indirect public enum WIRValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case data(Data)
    case dictionary([String: Self])
    case array([Self])

    public var string: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    public var int: Int? {
        if case let .int(value) = self {
            return value
        }
        return nil
    }

    public var data: Data? {
        if case let .data(value) = self {
            return value
        }
        return nil
    }

    public var dictionary: [String: Self]? {
        if case let .dictionary(value) = self {
            return value
        }
        return nil
    }

    init?(plist: Any) {
        switch plist {
        case let value as String: self = .string(value)
        case let value as Data: self = .data(value)
        #if canImport(Darwin)
        // NSNumber bridges both; check the CF type so `true` does not become `1`.
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): self = .bool(value.boolValue)
        #else
        case let value as Bool: self = .bool(value)
        #endif
        case let value as NSNumber: self = .int(value.intValue)
        case let value as [String: Any]: self = .dictionary(value.compactMapValues(Self.init(plist:)))
        case let value as [Any]: self = .array(value.compactMap(Self.init(plist:)))
        default: return nil
        }
    }

    var plist: Any {
        switch self {
        case let .string(value): value
        case let .bool(value): value
        case let .int(value): value
        case let .data(value): value
        case let .dictionary(value): value.mapValues(\.plist)
        case let .array(value): value.map(\.plist)
        }
    }
}

enum WIRCodec {
    static func encode(selector: String, argument: [String: WIRValue]) throws -> Data {
        let body = try PropertyListSerialization.data(
            fromPropertyList: ["__selector": selector, "__argument": argument.mapValues(\.plist)],
            format: .binary,
            options: 0
        )
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    static func decode(_ body: Data) -> WIRMessage? {
        guard let root = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
              let selector = root["__selector"] as? String
        else { return nil }
        let argument = (root["__argument"] as? [String: Any])?.compactMapValues(WIRValue.init(plist:)) ?? [:]
        return WIRMessage(selector: selector, argument: argument)
    }
}

/// Inbound messages buffered for one consumer. A timed-out wait leaves the queue intact — unlike
/// cancelling a task blocked on `AsyncStream.next()`, which terminates the whole stream (that
/// made the first timeout look like "webinspectord closed the connection").
final class WIRMessageQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [WIRMessage] = []
    private var finished = false
    private var waiter: (token: UUID, continuation: CheckedContinuation<WIRMessage?, any Error>)?

    func push(_ message: WIRMessage) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.continuation.resume(returning: message)
            return
        }
        buffer.append(message)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        finished = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.continuation.resume(returning: nil)
    }

    func next(timeout: Duration) async throws -> WIRMessage? {
        let token = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffer.isEmpty {
                let message = buffer.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
                return
            }
            if finished {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = (token, continuation)
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expire(token)
            }
        }
    }

    private func expire(_ token: UUID) {
        lock.lock()
        guard let waiter, waiter.token == token else {
            lock.unlock()
            return
        }
        self.waiter = nil
        lock.unlock()
        waiter.continuation.resume(throwing: WebInspectorError.timedOut(milliseconds: 0))
    }
}

#if canImport(Darwin)
/// `WebKitRPCChannel` over the simulator's `webinspectord_sim` unix socket
/// (`xcrun simctl getenv <udid> RWI_LISTEN_SOCKET`).
public final class UnixSocketWebKitChannel: WebKitRPCChannel, @unchecked Sendable {
    private let descriptor: Int32
    private let queue = WIRMessageQueue()
    private let lock = NSLock()
    private var closed = false

    public init(socketPath: String) throws {
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw WebInspectorError.transportUnavailable("socket(): \(String(cString: strerror(errno)))")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketDescriptor)
            throw WebInspectorError.transportUnavailable("socket path too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            pathBytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socketDescriptor)
            throw WebInspectorError.transportUnavailable("connect(\(socketPath)): \(reason)")
        }
        descriptor = socketDescriptor

        let queue = queue
        let reader = Thread {
            while let body = Self.readFrame(socketDescriptor) {
                if let message = WIRCodec.decode(body) {
                    queue.push(message)
                }
            }
            queue.finish()
        }
        reader.name = "amoo.webinspector.reader"
        reader.start()
    }

    public func send(selector: String, argument: [String: WIRValue]) async throws {
        let frame = try WIRCodec.encode(selector: selector, argument: argument)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else {
                    throw WebInspectorError
                        .transportUnavailable("webinspectord write failed: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
    }

    public func receive(timeout: Duration) async throws -> WIRMessage? {
        try await queue.next(timeout: timeout)
    }

    public func close() async {
        let shouldClose = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed
        }
        if shouldClose {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private static func readFrame(_ descriptor: Int32) -> Data? {
        guard let header = readExactly(descriptor, count: 4) else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length < 64 * 1024 * 1024 else { return nil }
        return readExactly(descriptor, count: length)
    }

    private static func readExactly(_ descriptor: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            while offset < count {
                let received = read(descriptor, buffer.baseAddress! + offset, count - offset)
                guard received > 0 else { return false }
                offset += received
            }
            return true
        }
        return ok ? data : nil
    }
}
#endif
