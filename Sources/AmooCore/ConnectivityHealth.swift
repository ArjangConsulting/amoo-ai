import Foundation

/// Independent, bounded transport probes. A responding channel does not establish app or rendering readiness.
public struct ConnectivityHealth: Sendable, Codable, Equatable {
    public struct Probe: Sendable, Codable, Equatable {
        public var status: String
        public var elapsedMS: Int
        public var source: String

        public init(status: String = "unavailable", elapsedMS: Int = 0, source: String) {
            self.status = status
            self.elapsedMS = elapsedMS
            self.source = source
        }
    }

    public var deviceTransport: Probe
    public var companionRPC: Probe

    public var failureScope: String {
        if ["failed", "timed_out"].contains(deviceTransport.status) {
            return "device_transport"
        }
        if deviceTransport.status == "responded", ["failed", "timed_out"].contains(companionRPC.status) {
            return "companion_channel"
        }
        return deviceTransport.status == "responded" && companionRPC.status == "responded" ? "none" : "unknown"
    }

    public init(deviceTransport: Probe, companionRPC: Probe) {
        self.deviceTransport = deviceTransport
        self.companionRPC = companionRPC
    }

    /// Measures read-only work under its own monotonic deadline and retains a timeout as uncertainty about that
    /// channel.
    public static func probe(
        source: String, operation: @escaping @Sendable () async throws -> Void
    ) async -> Probe {
        let started = ContinuousClock.now
        let status: String
        do {
            try await OperationDeadline.read(until: started + .seconds(2), operation: operation)
            status = "responded"
        } catch is OperationDeadline.DeadlineExceeded {
            status = "timed_out"
        } catch {
            status = "failed"
        }
        let elapsed = started.duration(to: .now).components
        return Probe(
            status: status,
            elapsedMS: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
            source: source
        )
    }
}

public extension PlatformDriver {
    func connectivityHealth() async -> ConnectivityHealth {
        ConnectivityHealth(
            deviceTransport: .init(source: "No independent device probe implemented"),
            companionRPC: .init(source: "No companion probe implemented")
        )
    }
}
