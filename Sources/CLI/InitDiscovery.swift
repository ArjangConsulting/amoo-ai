import AmooCore
import Foundation
import MobileDevices

// MARK: - Discovery

struct InitDeviceCandidate: Equatable {
    var id: String
    var name: String
    var detail: String
    var booted: Bool
    /// Runtime summary when another session holds the device; nil when it is free to take.
    var controlledBy: String?

    var label: String {
        let state = controlledBy.map { "controlled: \($0)" } ?? (booted ? "booted" : "shutdown")
        return "\(name) — \(detail), \(state) (\(id))"
    }
}

/// Host facts the wizard and validator need; replaced wholesale in tests.
struct InitDiscovery {
    var devices: (Platform) async -> [InitDeviceCandidate]
    var bundleID: (_ appPath: String, _ platform: Platform) -> String?
    /// Platform repositories below an orchestrator root, relative to it. Tests that do not exercise
    /// detection get none, so they never scan the checkout they run from.
    var repos: (_ root: URL, _ platform: Platform) -> [String] = { _, _ in [] }

    static func live(store: DeviceRuntimeStore = DeviceRuntimeStore()) -> Self {
        Self(
            devices: { await discoverInitDevices(platform: $0, store: store) },
            bundleID: { path, platform in platform == .ios ? iosBundleIdentifier(ofApp: path) : nil },
            repos: { detectInitRepos(at: $0, platform: $1) }
        )
    }
}

private func discoverInitDevices(platform: Platform, store: DeviceRuntimeStore) async -> [InitDeviceCandidate] {
    let found: [InitDeviceCandidate]
    switch platform {
    case .ios:
        let selector = DeviceSelector()
        let available = await selector.listAvailableSimulators()
        let booted = await Set(selector.listBootedDevices().filter { !$0.isPhysicalDevice }.map(\.udid))
        found = available.map {
            InitDeviceCandidate(
                id: $0.udid,
                name: $0.name,
                detail: "iOS \($0.osVersion)",
                booted: booted.contains($0.udid),
                controlledBy: store.runtime(forDevice: $0.udid)?.summary
            )
        }
    case .android:
        let online = await AndroidDeviceSelector().listOnlineDevices()
        found = online.filter { $0.serial.hasPrefix("emulator-") }.map {
            InitDeviceCandidate(
                id: $0.serial,
                name: $0.name,
                detail: "Android emulator",
                booted: true,
                controlledBy: store.runtime(forDevice: $0.serial)?.summary
            )
        }
    }

    return found
}

func sortedInitDevices(_ devices: [InitDeviceCandidate]) -> [InitDeviceCandidate] {
    devices.sorted { lhs, rhs in
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        let detailOrder = lhs.detail.localizedStandardCompare(rhs.detail)
        if detailOrder != .orderedSame {
            return detailOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}

func iosBundleIdentifier(ofApp path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path + "/Info.plist"),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist["CFBundleIdentifier"] as? String
}
