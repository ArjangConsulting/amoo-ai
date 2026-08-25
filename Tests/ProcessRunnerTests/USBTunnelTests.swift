#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import XCTest

/// Tests for ``IProxyTunnel``.
///
/// The success path binds a real loopback listener so the readiness poll resolves
/// immediately — production waits for the port to accept connections, and without a
/// listener every test would sit through the full timeout.
final class USBTunnelTests: XCTestCase {
    // MARK: - Availability

    func testIsAvailableReflectsWhichExitCode() async {
        let present = IProxyTunnel(
            context: MockShellExecutor(result: .init(exitCode: 0, stdout: "/opt/homebrew/bin/iproxy", stderr: ""))
                .context
        )
        let absent = IProxyTunnel(
            context: MockShellExecutor(result: .init(exitCode: 1, stdout: "", stderr: "")).context
        )

        let presentResult = await present.isAvailable()
        let absentResult = await absent.isAvailable()

        XCTAssertTrue(presentResult)
        XCTAssertFalse(absentResult)
    }

    func testOpenThrowsSetupRequiredWithInstallHintWhenIproxyMissing() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 1, stdout: "", stderr: ""))
        let tunnel = IProxyTunnel(context: mock.context)

        do {
            _ = try await tunnel.open(deviceUDID: "UDID-1", localPort: 22087, devicePort: 22087)
            XCTFail("Expected open to fail when iproxy is missing")
        } catch let error as AmooError {
            guard case let .setupRequired(tool, hint) = error else {
                return XCTFail("Expected setupRequired, got \(error)")
            }
            XCTAssertEqual(tool, "iproxy")
            // The hint has to carry the install command; this is the only place a user
            // learns why a device run failed.
            XCTAssertTrue(hint.contains("brew install libimobiledevice"))
        }
    }

    // MARK: - Open

    // `USBTunnelHandle.canConnect(toPort:)` is deliberately stubbed to always return `false` on
    // non-Darwin platforms (physical-iOS-device tunneling has no Linux use case), so the
    // readiness poll this test exercises can never succeed there.
    #if os(macOS)
    func testOpenForwardsLocalToDevicePortForSpecificUDID() async throws {
        let listener = try LoopbackListener()
        defer { listener.shutdown() }

        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let tunnel = IProxyTunnel(context: mock.context)

        let handle = try await tunnel.open(
            deviceUDID: "UDID-1",
            localPort: listener.port,
            devicePort: 22087
        )

        let commands = await mock.recordedCommands()
        // First command is the availability probe, second is the tunnel itself.
        XCTAssertEqual(commands.last, ["iproxy", "\(listener.port):22087", "-u", "UDID-1"])
        XCTAssertEqual(handle.localPort, listener.port)
        XCTAssertEqual(handle.devicePort, 22087)
        XCTAssertEqual(handle.deviceUDID, "UDID-1")
    }
    #endif

    func testOpenFailsWhenPortNeverAcceptsConnections() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        // Short timeout so this exercises the failure path without padding the suite.
        let tunnel = IProxyTunnel(context: mock.context, readinessTimeoutSeconds: 0.3)

        do {
            // Nothing is listening here, so readiness must time out rather than hand back
            // a handle that looks valid but routes nowhere.
            _ = try await tunnel.open(deviceUDID: "UDID-1", localPort: unusedPort(), devicePort: 22087)
            XCTFail("Expected open to fail when the tunnel never starts listening")
        } catch let error as AmooError {
            guard case let .commandFailed(_, output) = error else {
                return XCTFail("Expected commandFailed, got \(error)")
            }
            XCTAssertTrue(output.contains("did not start listening"))
        }
    }

    // MARK: - Close

    func testCloseSignalsUntrackedTunnelByPID() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let tunnel = IProxyTunnel(context: mock.context)

        try await tunnel.close(
            USBTunnelHandle(localPort: 5000, devicePort: 22087, deviceUDID: "UDID-1", processIdentifier: 4242)
        )

        let commands = await mock.recordedCommands()
        // SIGINT, not SIGKILL, so iproxy can tear the forward down cleanly.
        XCTAssertEqual(commands, [["kill", "-INT", "4242"]])
    }

    // MARK: - Helpers

    /// A port with nothing bound to it, obtained by binding then immediately releasing.
    private func unusedPort() -> Int {
        let listener = try? LoopbackListener()
        let port = listener?.port ?? 49999
        listener?.shutdown()
        return port
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
