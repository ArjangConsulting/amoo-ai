import Foundation
#if canImport(Network)
import Network
#else
import Glibc
#endif

/// Checks whether a TCP port accepts a connection within a timeout.
///
/// Shared by every companion-readiness poll (iOS `CompanionManager`, Android
/// `AndroidCompanionManager`, `ChatCommand`) so the platform split lives in one place.
public func isTCPPortReachable(host: String, port: Int, timeoutSeconds: Double) async -> Bool {
    #if canImport(Network)
    await withCheckedContinuation { continuation in
        let box = TCPReachabilityBox(continuation: continuation)
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port)),
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.cancel()
                box.resolve(true)
            case .failed, .cancelled:
                box.resolve(false)
            default:
                break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
            connection.cancel()
            box.resolve(false)
        }
    }
    #else
    await Task.detached(priority: .utility) {
        posixTCPReachable(host: host, port: port, timeoutSeconds: timeoutSeconds)
    }.value
    #endif
}

#if canImport(Network)

private final class TCPReachabilityBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var resolved = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation.resume(returning: value)
    }
}

#else

/// The `Network` framework doesn't exist on Linux. This is a synchronous, blocking TCP connect
/// with a timeout using plain POSIX sockets — intended to run off the main actor via
/// `Task.detached`, mirroring what NWConnection does asynchronously on Darwin.
private func posixTCPReachable(host: String, port: Int, timeoutSeconds: Double) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)

    var resultPointer: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &resultPointer) == 0,
          let firstAddr = resultPointer
    else { return false }
    defer { freeaddrinfo(resultPointer) }

    var addrInfo: UnsafeMutablePointer<addrinfo>? = firstAddr
    while let current = addrInfo {
        if connectWithTimeout(current.pointee, timeoutSeconds: timeoutSeconds) {
            return true
        }
        addrInfo = current.pointee.ai_next
    }
    return false
}

private func connectWithTimeout(_ addr: addrinfo, timeoutSeconds: Double) -> Bool {
    let fd = socket(addr.ai_family, addr.ai_socktype, addr.ai_protocol)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    let connectResult = connect(fd, addr.ai_addr, addr.ai_addrlen)
    if connectResult == 0 {
        return true
    }
    guard errno == EINPROGRESS else { return false }

    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pollFD, 1, Int32(timeoutSeconds * 1000)) > 0 else { return false }

    var socketError: Int32 = 0
    var errorLength = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength)
    return socketError == 0
}

#endif
