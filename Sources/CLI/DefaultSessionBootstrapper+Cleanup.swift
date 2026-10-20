import AmooCore
import CompanionProtocol
import Foundation
import MobileDevices
import ProcessRunner
import TestSession

extension DefaultSessionBootstrapper {
    struct SessionOwnership: Sendable {
        let deviceKey: String
        let owner: UUID
        let accessLock: DeviceAccessLock
    }

    /// What ending a session releases: the gRPC client, any USB tunnel, device access — and, for a
    /// simulator, a pending stop of its companion once it has been idle (see
    /// `CompanionManager.idleShutdownSeconds`), so a companion does not outlive its sessions forever.
    func makeSessionCleanup(
        companion: GRPCCompanionClient,
        tunnelHandle: USBTunnelHandle?,
        ownership: SessionOwnership,
        device: AvailableDevice
    ) -> @Sendable () async -> Void {
        let tunnel = usbTunnel
        let companionManager = iOSCompanionManager
        let idleSeconds = CompanionManager.idleShutdownSeconds()
        let simulatorUDID: String? = if case let .ios(booted) = device, !booted.isPhysicalDevice {
            booted.udid
        } else {
            nil
        }
        return { [companion, tunnelHandle, tunnel] in
            await companion.shutdown()
            if let tunnelHandle {
                try? await tunnel.close(tunnelHandle)
            }
            await Self.deviceAccess.release(ownership.deviceKey, owner: ownership.owner)
            ownership.accessLock.release()
            if let simulatorUDID {
                companionManager.scheduleIdleShutdown(deviceUDID: simulatorUDID, after: idleSeconds)
            }
        }
    }
}
