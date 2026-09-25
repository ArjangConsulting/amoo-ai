import AmooCore
import Foundation

// MARK: - Parsing

func parseBootedDevices(json: String) -> [BootedDevice] {
    guard let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let devices = root["devices"] as? [String: [[String: Any]]]
    else { return [] }

    var result: [BootedDevice] = []
    for (runtime, deviceList) in devices {
        guard runtime.contains("iOS") else { continue }
        let osVersion =
            runtime
                .components(separatedBy: "iOS-").last?
                .replacingOccurrences(of: "-", with: ".") ?? ""

        for device in deviceList {
            guard let udid = device["udid"] as? String,
                  let name = device["name"] as? String,
                  let state = device["state"] as? String,
                  state == "Booted"
            else { continue }
            result.append(BootedDevice(udid: udid, name: name, osVersion: osVersion))
        }
    }
    return result.sorted { $0.name < $1.name }
}

/// Parses `devicectl list devices --json-output` into connected, drivable iOS devices.
///
/// Only devices whose tunnel is established are returned — a paired-but-unplugged phone
/// appears in the list but can't be driven, so offering it would just fail later.
func parseConnectedIOSDevices(json: String) -> [BootedDevice] {
    guard let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = root["result"] as? [String: Any],
          let devices = result["devices"] as? [[String: Any]]
    else { return [] }

    var connected: [BootedDevice] = []
    for device in devices {
        let properties = device["deviceProperties"] as? [String: Any] ?? [:]
        let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
        let connection = device["connectionProperties"] as? [String: Any] ?? [:]

        guard connection["tunnelState"] as? String == "connected" else { continue }
        // Only iOS — devicectl also reports paired Watches, Apple TVs, and Macs.
        guard (hardware["platform"] as? String ?? "iOS") == "iOS" else { continue }
        // Xcode 27's devicectl lists simulators too, as `reality: simulated`, and a booted one is
        // `connected` — so every booted simulator read as physical and launches went through
        // devicectl, which cannot find the process it started there. Older devicectl listed only
        // hardware and omits the field, hence the default.
        guard (hardware["reality"] as? String ?? "physical") != "simulated" else { continue }

        let identifier = device["identifier"] as? String ?? ""
        let udid = hardware["udid"] as? String ?? identifier
        guard !udid.isEmpty else { continue }

        connected.append(
            BootedDevice(
                udid: udid,
                name: properties["name"] as? String ?? udid,
                osVersion: properties["osVersionNumber"] as? String ?? "unknown",
                isPhysicalDevice: true
            )
        )
    }
    return connected.sorted { $0.name < $1.name }
}

func parseAvailableIOSSimulators(json: String) -> [IOSSimulatorDevice] {
    guard let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let devices = root["devices"] as? [String: [[String: Any]]]
    else { return [] }

    var result: [IOSSimulatorDevice] = []
    for (runtime, deviceList) in devices {
        guard runtime.contains("iOS") else { continue }
        let osVersion =
            runtime
                .components(separatedBy: "iOS-").last?
                .replacingOccurrences(of: "-", with: ".") ?? ""

        for device in deviceList {
            guard let udid = device["udid"] as? String,
                  let name = device["name"] as? String
            else { continue }
            result.append(IOSSimulatorDevice(udid: udid, name: name, osVersion: osVersion))
        }
    }
    return result.sorted {
        if $0.name == $1.name {
            return $0.osVersion > $1.osVersion
        }
        return $0.name < $1.name
    }
}

/// Parses `adb devices -l` output into (serial, name) pairs for online devices.
func parseADBDevices(output: String) -> [(serial: String, name: String)] {
    var results: [(serial: String, name: String)] = []
    let lines = output.components(separatedBy: .newlines)
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("List of devices") else { continue }
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2, parts[1] == "device" else { continue }
        let serial = parts[0]
        // Extract model name from "model:Pixel_7" token if present, else fall back to serial
        let name: String = if let modelToken = parts.first(where: { $0.hasPrefix("model:") }) {
            modelToken
                .replacingOccurrences(of: "model:", with: "")
                .replacingOccurrences(of: "_", with: " ")
        } else {
            serial
        }
        results.append((serial: serial, name: name))
    }
    return results
}

func parseAndroidVirtualDevices(output: String) -> [AndroidVirtualDevice] {
    output
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map(AndroidVirtualDevice.init(name:))
}

// MARK: - Interactive selection

/// Whether stdin is an interactive terminal rather than a pipe.
///
/// `amoo mcp serve` and other headless invocations have stdin bound to a protocol
/// stream, not a keyboard — `readLine()` there either blocks forever waiting for
/// input that will never come, or silently consumes bytes meant for the protocol.
/// Every multi-candidate selection path must check this before prompting.
func isInteractiveStdin() -> Bool {
    isatty(STDIN_FILENO) != 0
}

/// Ranks candidates for a non-interactive auto-pick, preferring non-physical
/// targets (simulators/emulators) first, since a physical device is more likely
/// to be locked, unattended, or otherwise unsuited to being picked blindly.
/// Ties keep their original (already-sorted) order.
func rankPreferringNonPhysical<T>(_ items: [T], isPhysical: (T) -> Bool) -> [T] {
    items.enumerated().sorted { lhs, rhs in
        let lhsPhysical = isPhysical(lhs.element)
        let rhsPhysical = isPhysical(rhs.element)
        if lhsPhysical != rhsPhysical {
            return rhsPhysical
        }
        return lhs.offset < rhs.offset
    }.map(\.element)
}

/// Picks a candidate without prompting, ranking non-physical targets first, and prints
/// which alternatives were passed over so the choice is explainable instead of silent.
func autoSelectDevice<T>(
    from candidates: [T],
    displayName: (T) -> String,
    isPhysical: (T) -> Bool
) -> T {
    let ranked = rankPreferringNonPhysical(candidates, isPhysical: isPhysical)
    // Callers only reach here with a non-empty list (the 0/1-candidate cases are
    // handled before falling into the multi-candidate branch).
    let chosen = ranked[0]
    let others = ranked.dropFirst()
    let suffix = others.isEmpty ? "" : " — \(others.count) other candidate(s) available "
        + "(\(others.map(displayName).joined(separator: ", "))); pass device_hint to choose one"
    FileHandle.standardError.write(Data("Auto-selected: \(displayName(chosen))\(suffix)\n".utf8))
    return chosen
}

func promptiOSDeviceSelection(from devices: [BootedDevice]) throws -> BootedDevice {
    try promptSelection(
        title: "\nMultiple booted simulators found:",
        prompt: "Select a device",
        items: devices,
        displayName: \.displayName,
        eofError: .noBootedSimulators
    )
}

func promptDeviceSelection(from devices: [AvailableDevice]) throws -> AvailableDevice {
    try promptSelection(
        title: "\nAvailable devices:",
        prompt: "Select a device",
        items: devices,
        displayName: \.displayName,
        eofError: .noDevicesAvailable,
        colorNumbers: true
    )
}

func promptSelection<T>(
    title: String,
    prompt: String,
    items: [T],
    displayName: (T) -> String,
    eofError: DeviceSelectionError = .noDevicesAvailable,
    colorNumbers: Bool = false
) throws -> T {
    guard isInteractiveStdin() else {
        guard let first = items.first else { throw eofError }
        FileHandle.standardError.write(Data("Auto-selected: \(displayName(first))\n".utf8))
        return first
    }
    print(title)
    for (index, item) in items.enumerated() {
        let number = colorNumbers ? colored("\(index + 1))", .cyan) : "\(index + 1))"
        print("  \(number) \(displayName(item))")
    }
    print("")

    while true {
        print("\(prompt) [1-\(items.count)]: ", terminator: "")
        fflush(nil) // flush all open streams — avoids referencing the `stdout` global directly

        guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) else {
            throw eofError
        }
        guard let index = Int(line), index >= 1, index <= items.count else {
            print("Invalid selection. Enter a number between 1 and \(items.count).")
            continue
        }
        return items[index - 1]
    }
}

#if DEBUG
func test_parseAvailableIOSSimulators(json: String) -> [IOSSimulatorDevice] {
    parseAvailableIOSSimulators(json: json)
}

func test_parseConnectedIOSDevices(json: String) -> [BootedDevice] {
    parseConnectedIOSDevices(json: json)
}

func test_parseAndroidVirtualDevices(output: String) -> [AndroidVirtualDevice] {
    parseAndroidVirtualDevices(output: output)
}

func test_availablePlatforms(
    iosSimulators: [IOSSimulatorDevice],
    androidVirtualDevices: [AndroidVirtualDevice]
) -> [Platform] {
    availablePlatforms(iosSimulators: iosSimulators, androidVirtualDevices: androidVirtualDevices)
}
#endif
