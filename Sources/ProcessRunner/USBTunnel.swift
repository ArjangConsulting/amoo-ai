#if canImport(Darwin)
import Darwin
#endif
import Foundation
import MobileTestingCore
import SwiftyShell

/// A live host→device TCP forward, so host code can reach a port on a physical device.
public struct USBTunnelHandle: Sendable, Equatable {
    /// Port on the host that forwards to the device.
    public let localPort: Int
    /// Port the companion listens on, on the device.
    public let devicePort: Int
    public let deviceUDID: String
    /// PID of the forwarding process, used to tear the tunnel down.
    public let processIdentifier: Int32

    public init(localPort: Int, devicePort: Int, deviceUDID: String, processIdentifier: Int32) {
        self.localPort = localPort
        self.devicePort = devicePort
        self.deviceUDID = deviceUDID
        self.processIdentifier = processIdentifier
    }
}

/// Forwards a host port to a port on a physical iOS device over USB.
///
/// Simulators share localhost with the host, so the companion is directly reachable
/// and no tunnel is needed. Physical devices don't, and unlike Android — where
/// `adb forward` is built in — `devicectl` ships no port-forwarding command. So the
/// tunnel has to come from outside Apple's toolchain.
public protocol USBTunneling: Sendable {
    /// Whether the underlying forwarding tool is installed and usable.
    func isAvailable() async -> Bool

    /// Opens a forward and waits until it actually accepts connections.
    func open(deviceUDID: String, localPort: Int, devicePort: Int) async throws -> USBTunnelHandle

    /// Tears down a previously opened forward. Safe to call for an already-closed tunnel.
    func close(_ handle: USBTunnelHandle) async throws
}

/// ``USBTunneling`` backed by `iproxy` from libimobiledevice.
public struct IProxyTunnel: USBTunneling {
    private let context: ShellContext
    private let readinessTimeoutSeconds: TimeInterval

    /// - Parameter readinessTimeoutSeconds: How long ``open(deviceUDID:localPort:devicePort:)``
    ///   waits for the forward to accept connections before giving up. Exposed so tests can
    ///   exercise the timeout path without stalling.
    public init(context: ShellContext = .init(), readinessTimeoutSeconds: TimeInterval = 5.0) {
        self.context = context
        self.readinessTimeoutSeconds = readinessTimeoutSeconds
    }

    public func isAvailable() async -> Bool {
        let result = try? await SystemProcessRunner(context: context).run(["which", "iproxy"])
        return (result?.exitCode ?? 1) == 0
    }

    public func open(
        deviceUDID: String,
        localPort: Int,
        devicePort: Int
    ) async throws -> USBTunnelHandle {
        guard await isAvailable() else {
            throw MobileTestingError.setupRequired(
                tool: "iproxy",
                hint: """
                Physical iOS devices need a USB tunnel to reach the companion, and \
                `xcrun devicectl` provides no port forwarding of its own.
                Install it with: brew install libimobiledevice
                (`iproxy` ships in libusbmuxd, which that formula pulls in and links.)
                Simulators don't need this — they share localhost with the host.
                """
            )
        }

        let command = Command("iproxy").args(["\(localPort):\(devicePort)", "-u", deviceUDID])
        let process = try await command.spawn(in: context, teardown: .interruptThenTerminate)
        await USBTunnelRegistry.shared.register(process)

        let handle = USBTunnelHandle(
            localPort: localPort,
            devicePort: devicePort,
            deviceUDID: deviceUDID,
            processIdentifier: process.processIdentifier
        )

        // iproxy binds asynchronously; dialing before it listens fails the first
        // connection and surfaces as a spurious "companion unreachable".
        guard await Self.waitForPort(localPort, timeoutSeconds: readinessTimeoutSeconds) else {
            try? await close(handle)
            throw MobileTestingError.commandFailed(
                command: "iproxy \(localPort):\(devicePort) -u \(deviceUDID)",
                output: """
                Tunnel did not start listening on port \(localPort) within \
                \(readinessTimeoutSeconds)s.
                Check the device is connected and trusted: xcrun devicectl list devices
                """
            )
        }

        return handle
    }

    public func close(_ handle: USBTunnelHandle) async throws {
        if let process = await USBTunnelRegistry.shared.remove(pid: handle.processIdentifier) {
            try await process.interrupt()
            _ = await process.waitForExit()
            return
        }

        _ = try await SystemProcessRunner(context: context)
            .run(["kill", "-INT", String(handle.processIdentifier)])
    }

    // MARK: - Readiness

    /// Note: `Duration` unqualified is MobileTestingCore's own type, not Swift's.
    private static let readinessPollInterval = Swift.Duration.milliseconds(100)

    /// Polls until something accepts TCP connections on `port`, or the timeout elapses.
    private static func waitForPort(_ port: Int, timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if canConnect(toPort: port) {
                return true
            }
            try? await Task.sleep(for: readinessPollInterval)
        }
        return false
    }

    /// Attempts a single loopback TCP connection, returning whether it succeeded.
    private static func canConnect(toPort port: Int) -> Bool {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
        #else
        return false
        #endif
    }
}

private actor USBTunnelRegistry {
    static let shared = USBTunnelRegistry()

    private var processes: [Int32: any SpawnedProcess] = [:]

    func register(_ process: any SpawnedProcess) {
        processes[process.processIdentifier] = process
    }

    func remove(pid: Int32) -> (any SpawnedProcess)? {
        processes.removeValue(forKey: pid)
    }
}
