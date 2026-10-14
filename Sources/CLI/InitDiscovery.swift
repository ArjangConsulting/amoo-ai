import AmooCore
import Foundation
import MobileDevices

// MARK: - Discovery

struct InitDeviceCandidate: Equatable {
    var id: String
    var name: String
    var detail: String
    var booted: Bool
    /// Lease summary when another session holds the device; nil when it is free to take.
    var leasedBy: String?

    var label: String {
        let state = leasedBy.map { "leased: \($0)" } ?? (booted ? "booted" : "shutdown")
        return "\(name) — \(detail), \(state) (\(id))"
    }
}

/// Host facts the wizard and validator need; replaced wholesale in tests.
struct InitDiscovery {
    var devices: (Platform) async -> [InitDeviceCandidate]
    var apps: (Platform) -> [String]
    var bundleID: (_ appPath: String, _ platform: Platform) -> String?

    static func live(store: DeviceClaimStore = DeviceClaimStore()) -> Self {
        Self(
            devices: { await discoverInitDevices(platform: $0, store: store) },
            apps: { platform in
                let home = FileManager.default.homeDirectoryForCurrentUser
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                let roots = platform == .ios
                    ? [cwd, home.appendingPathComponent("Library/Developer/Xcode/DerivedData")]
                    : [cwd]
                return discoverAppArtifacts(platform: platform, roots: roots)
            },
            bundleID: { path, platform in platform == .ios ? iosBundleIdentifier(ofApp: path) : nil }
        )
    }
}

private func discoverInitDevices(platform: Platform, store: DeviceClaimStore) async -> [InitDeviceCandidate] {
    var found: [InitDeviceCandidate]
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
                leasedBy: store.claim(forDevice: $0.udid)?.summary
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
                leasedBy: store.claim(forDevice: $0.serial)?.summary
            )
        }
    }
    // Free and already-booted first: reuse is cheaper than a boot, and a leased row is not selectable.
    found.sort { lhs, rhs in
        let lhsRank = (lhs.leasedBy == nil ? 0 : 2) + (lhs.booted ? 0 : 1)
        let rhsRank = (rhs.leasedBy == nil ? 0 : 2) + (rhs.booted ? 0 : 1)
        return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.name < rhs.name
    }
    return found
}

/// Built apps near the caller, newest first: simulator `.app` bundles (never UI-test runners) or
/// non-test `.apk` files under a Gradle `outputs/apk` directory.
func discoverAppArtifacts(platform: Platform, roots: [URL], maxDepth: Int = 8, limit: Int = 8) -> [String] {
    let pruned: Set = ["node_modules", "Pods", "Index.noindex", "Intermediates.noindex", "SourcePackages", "Logs"]
    var matches: [(path: String, modified: Date)] = []
    for root in roots {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for case let url as URL in walker {
            if walker.level > maxDepth || pruned.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let path = url.path
            switch platform {
            case .ios where url.pathExtension == "app":
                walker.skipDescendants()
                guard path.contains("iphonesimulator"),
                      !url.lastPathComponent.hasSuffix("-Runner.app"),
                      url.lastPathComponent != "AmooCompanion.app" else { continue }
            case .android where url.pathExtension == "apk":
                guard path.contains("/outputs/apk/"), !path.contains("androidTest") else { continue }
            default:
                continue
            }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            matches.append((path, modified))
        }
    }
    var seen = Set<String>()
    return matches.sorted { $0.modified > $1.modified }
        .map(\.path)
        .filter { seen.insert($0).inserted }
        .prefix(limit)
        .map(\.self)
}

func iosBundleIdentifier(ofApp path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path + "/Info.plist"),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist["CFBundleIdentifier"] as? String
}
