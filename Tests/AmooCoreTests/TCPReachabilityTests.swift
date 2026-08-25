import AmooCore
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class TCPReachabilityTests: XCTestCase {
    func testReachablePortReturnsTrue() async throws {
        let listener = try LoopbackListener()
        defer { listener.shutdown() }

        let reachable = await isTCPPortReachable(host: "127.0.0.1", port: listener.port, timeoutSeconds: 2.0)

        XCTAssertTrue(reachable)
    }

    func testUnusedPortReturnsFalse() async throws {
        let listener = try LoopbackListener()
        let port = listener.port
        listener.shutdown()

        let reachable = await isTCPPortReachable(host: "127.0.0.1", port: port, timeoutSeconds: 0.3)

        XCTAssertFalse(reachable)
    }
}

/// Binds and listens on an ephemeral loopback port so connection attempts succeed.
private final class LoopbackListener {
    let port: Int
    private let descriptor: Int32

    init() throws {
        // Use a local until every stored property is set — closures below capture it,
        // and capturing `self.descriptor` before `port` exists is not allowed.
        // `SOCK_STREAM` is already `Int32` on Darwin but an `__socket_type` enum on Glibc.
        #if canImport(Darwin)
        let socketType = SOCK_STREAM
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fileDescriptor = socket(AF_INET, socketType, 0)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: "LoopbackListener", code: 1)
        }

        var reuse: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // let the kernel pick a free port
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fileDescriptor, 1) == 0 else {
            close(fileDescriptor)
            throw NSError(domain: "LoopbackListener", code: 2)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fileDescriptor, socketAddress, &length)
            }
        }
        guard named == 0 else {
            close(fileDescriptor)
            throw NSError(domain: "LoopbackListener", code: 3)
        }

        descriptor = fileDescriptor
        port = Int(UInt16(bigEndian: actual.sin_port))
    }

    func shutdown() {
        close(descriptor)
    }
}
