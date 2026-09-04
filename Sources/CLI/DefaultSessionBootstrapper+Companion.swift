import AmooCore
import Foundation
import IOSDriver
import ProcessRunner
import TestSession

/// `device_hint` / `include_offline` device selection and the `companion warm` / `companion status`
/// lifecycle, kept out of `DefaultSessionBootstrapper.swift` so that file stays under the
/// type-body length limit.
extension DefaultSessionBootstrapper {
    func listDevices(platform: Platform?, includeOffline: Bool) async throws -> [DeviceInfo] {
        var result = try await listDevices(platform: platform)
        guard includeOffline else { return result }
        let known = Set(result.map(\.id))

        if platform == nil || platform == .ios {
            let sims = await DeviceSelector(processRunner: processRunner).listAvailableSimulators()
            result += sims.filter { !known.contains($0.udid) }.map { sim in
                DeviceInfo(
                    id: sim.udid,
                    name: sim.name,
                    platform: .ios,
                    osVersion: sim.osVersion,
                    state: .shutdown
                )
            }
        }
        if platform == nil || platform == .android {
            let avds = await AndroidDeviceSelector(processRunner: processRunner).listAvailableVirtualDevices()
            result += avds.filter { !known.contains($0.name) }.map { avd in
                DeviceInfo(id: avd.name, name: avd.name, platform: .android, osVersion: "", state: .shutdown)
            }
        }
        return result
    }

    func bootDevice(hint: String, platform: Platform) async throws -> DeviceInfo {
        switch platform {
        case .ios:
            return try await bootIOSDevice(hint: hint)
        case .android:
            let online = await AndroidDeviceSelector(processRunner: processRunner).listOnlineDevices()
            let lowered = hint.lowercased()
            let match = ["device", "simulator", "emulator"].contains(lowered)
                ? online.first
                : online.first { $0.serial == hint || $0.name.lowercased() == lowered }
            guard let match else {
                throw BootstrapError.launchFailed(
                    "No online Android device matches '\(hint)'. Start the emulator first — "
                        + "amoo does not boot AVDs."
                )
            }
            return DeviceInfo(id: match.serial, name: match.name, platform: .android, osVersion: "", state: .booted)
        }
    }

    func warmCompanion(platform: Platform, deviceHint: String?, appID: String?) async throws -> String {
        let runner = processRunner
        switch platform {
        case .ios:
            let udid = await resolveIOSWarmDevice(hint: deviceHint)
            let config = CompanionConfig(deviceUDID: udid, targetAppID: appID)
            let store = CompanionStatusStore(companionDir: config.companionDir)
            let port = config.port
            store.write(warmRecord(.building, platform: "ios", device: udid, port: port, detail: "build"))
            Task.detached {
                let manager = CompanionManager(processRunner: runner)
                do {
                    try await manager.install(config: config)
                    store.write(warmRecord(.built, platform: "ios", device: udid, port: port, detail: nil))
                } catch {
                    let why = "\(error)"
                    store.write(warmRecord(.failed, platform: "ios", device: udid, port: port, detail: why))
                }
            }
            return "companion warm started (ios, port \(port)); poll companion_status."
        case .android:
            let config = AndroidCompanionConfig(serial: deviceHint)
            let store = CompanionStatusStore(companionDir: config.companionDir)
            let dev = deviceHint ?? ""
            let port = config.port
            store.write(warmRecord(.building, platform: "android", device: dev, port: port, detail: "build"))
            Task.detached {
                let manager = AndroidCompanionManager(processRunner: runner)
                do {
                    try await manager.install(config: config)
                    store.write(warmRecord(.built, platform: "android", device: dev, port: port, detail: nil))
                } catch {
                    let why = "\(error)"
                    store.write(warmRecord(.failed, platform: "android", device: dev, port: port, detail: why))
                }
            }
            return "companion warm started (android, port \(port)); poll companion_status."
        }
    }

    func companionStatus(platform: Platform, deviceHint: String?) async throws -> String {
        let host: String
        let port: Int
        let dir: String
        switch platform {
        case .ios:
            let config = CompanionConfig(deviceUDID: deviceHint ?? "booted")
            (host, port, dir) = (config.host, config.port, config.companionDir)
        case .android:
            let config = AndroidCompanionConfig(serial: deviceHint)
            (host, port, dir) = (config.host, config.port, config.companionDir)
        }
        let store = CompanionStatusStore(companionDir: dir)
        let result = await companionStatusResult(
            platform: platform.rawValue,
            host: host,
            port: port,
            store: store
        )
        return result.output
    }

    private func resolveIOSWarmDevice(hint: String?) async -> String {
        if let hint, !hint.isEmpty, hint.lowercased() != "simulator" {
            return hint
        }
        let booted = await DeviceSelector(processRunner: processRunner).listBootedDevices()
        return booted.first { !$0.isPhysicalDevice }?.udid ?? "booted"
    }

    private func bootIOSDevice(hint: String) async throws -> DeviceInfo {
        let selector = DeviceSelector(processRunner: processRunner)
        let lowered = hint.lowercased()
        let wantsClass = lowered == "simulator" || lowered == "device"

        let booted = await selector.listBootedDevices()
        let runningMatch = booted.first { device in
            if wantsClass {
                return lowered == "device" ? device.isPhysicalDevice : !device.isPhysicalDevice
            }
            return device.udid == hint || device.name.lowercased() == lowered
        }
        if let runningMatch {
            return DeviceInfo(
                id: runningMatch.udid,
                name: runningMatch.name,
                platform: .ios,
                osVersion: runningMatch.osVersion,
                state: .booted
            )
        }
        if lowered == "device" {
            throw BootstrapError.launchFailed("No connected physical iOS device found to boot into.")
        }

        // A shut-down simulator: resolve a real UDID, then boot it.
        let available = await selector.listAvailableSimulators()
        let target = wantsClass
            ? available.first
            : available.first { $0.udid == hint || $0.name.lowercased() == lowered }
        let udid = target?.udid ?? hint
        let backend = SimulatorHostBackend(simctl: SimctlRunner())
        try await backend.boot(device: udid)
        return try await backend.deviceInfo(device: udid)
    }
}
