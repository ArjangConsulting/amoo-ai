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

func launchDetachedProcess(arguments: [String]) throws {
    guard let executable = arguments.first else {
        throw DeviceSelectionError.launchFailed("Missing executable.")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + Array(arguments.dropFirst())
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        throw DeviceSelectionError.launchFailed(error.localizedDescription)
    }
}

// MARK: - Interactive selection

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
    print(title)
    for (index, item) in items.enumerated() {
        let number = colorNumbers ? colored("\(index + 1))", .cyan) : "\(index + 1))"
        print("  \(number) \(displayName(item))")
    }
    print("")

    while true {
        print("\(prompt) [1-\(items.count)]: ", terminator: "")
        fflush(stdout)

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
