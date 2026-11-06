import Foundation
import TestSession

extension DefaultSessionBootstrapper {
    func deviceLeases() async -> [String: SessionDeviceLease] {
        var leases: [String: SessionDeviceLease] = [:]
        for runtime in runtimeStore.all() {
            leases[runtime.deviceID] = SessionDeviceLease(
                owner: runtime.owner ?? runtime.id,
                runtimeID: runtime.id,
                expiresAt: runtime.expiresAt.ISO8601Format()
            )
        }
        let devices = await (try? listDevices(platform: nil, includeOffline: true)) ?? []
        for device in devices where leases[device.id] == nil {
            let path = runtimeStore.accessFileURL(deviceID: device.id).appendingPathExtension("session-lock").path
            if let holder = DeviceAccessHolder.read(path: path), holder.isAlive {
                leases[device.id] = SessionDeviceLease(owner: "pid \(holder.pid) (\(holder.command))")
            }
        }
        return leases
    }
}
