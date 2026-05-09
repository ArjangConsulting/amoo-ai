import Foundation
import MobileTestingCore
import ProcessRunner
import SwiftyShell

// MARK: - Types

struct BootedDevice {
    let udid: String
    let name: String
    let osVersion: String

    var displayName: String {
        "\(name) [iOS \(osVersion)] (\(udid))"
    }
}

/// A cross-platform representation of an available device or emulator/simulator.
enum AvailableDevice {
    case ios(BootedDevice)
    case android(serial: String, name: String)

    var platform: Platform {
        switch self {
        case .ios: .ios
        case .android: .android
        }
    }

    var displayName: String {
        switch self {
        case let .ios(device):
            "[iOS]     \(device.displayName)"
        case let .android(serial, name):
            "[Android] \(name) (\(serial))"
        }
    }
}

enum DeviceSelectionError: Error, CustomStringConvertible {
    case noBootedSimulators
    case noDevicesAvailable
    case invalidSelection(String)

    var description: String {
        switch self {
        case .noBootedSimulators:
            """
            No booted iOS simulator found.
            Boot one with:
              open -a Simulator
              xcrun simctl boot "<name-or-udid>"
            Then re-run amoo.
            """
        case .noDevicesAvailable:
            """
            No iOS simulators or Android emulators/devices found.
            - iOS: open -a Simulator  (or xcrun simctl boot "<name-or-udid>")
            - Android: start an emulator in Android Studio or connect a device
            Then re-run amoo.
            """
        case let .invalidSelection(input):
            "Invalid selection '\(input)'. Enter a number from the list."
        }
    }
}

// MARK: - iOS DeviceSelector (booted simulators)

struct DeviceSelector {
    private let processRunner: any ProcessRunner

    init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func selectDevice(hint: String? = nil) async throws -> BootedDevice {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        let devices = try await SimctlRunner(context: context).listDevices()
        let booted = parseBootedDevices(json: devices)

        if let hint {
            if let match = booted.first(where: {
                $0.udid == hint || $0.name.lowercased() == hint.lowercased()
            }) {
                return match
            }
            // Hint given but not booted - return a minimal device entry so caller can proceed if companion is already
            // up
            return BootedDevice(udid: hint, name: hint, osVersion: "unknown")
        }

        switch booted.count {
        case 0:
            throw DeviceSelectionError.noBootedSimulators
        case 1:
            let device = booted[0]
            print(colored("Auto-selected:", .cyan) + " \(device.displayName)")
            return device
        default:
            return try promptiOSDeviceSelection(from: booted)
        }
    }

    func listBootedDevices() async -> [BootedDevice] {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        guard let json = try? await SimctlRunner(context: context).listDevices() else { return [] }
        return parseBootedDevices(json: json)
    }
}

// MARK: - Android device listing

struct AndroidDeviceSelector {
    private let processRunner: any ProcessRunner

    init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    /// Returns serials and friendly names for all online Android emulators and physical devices.
    func listOnlineDevices() async -> [(serial: String, name: String)] {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        guard let output = try? await ADBRunner(context: context).listDevices() else { return [] }
        return parseADBDevices(output: output)
    }
}

// MARK: - Cross-platform PlatformDeviceSelector

struct PlatformDeviceSelector {
    private let processRunner: any ProcessRunner

    init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    /// Lists all available iOS simulators and Android devices/emulators concurrently,
    /// then prompts the user when more than one is found.
    func selectDevice(hint: String? = nil, platform: Platform? = nil) async throws -> AvailableDevice {
        let iosSelector = DeviceSelector(processRunner: processRunner)
        let androidSelector = AndroidDeviceSelector(processRunner: processRunner)

        async let iosDevices = iosSelector.listBootedDevices()
        async let androidDevices = androidSelector.listOnlineDevices()

        var all: [AvailableDevice] = []
        let ios = await iosDevices
        let android = await androidDevices

        if platform == nil || platform == .ios {
            all += ios.map { .ios($0) }
        }
        if platform == nil || platform == .android {
            all += android.map { .android(serial: $0.serial, name: $0.name) }
        }

        // Resolve a hint against all collected devices
        if let hint {
            if let match = all.first(where: { matchesHint($0, hint: hint) }) {
                return match
            }
            // Hint provided but device not in lists — allow caller to continue if companion is up
            if platform == .android {
                return .android(serial: hint, name: hint)
            }
            return .ios(BootedDevice(udid: hint, name: hint, osVersion: "unknown"))
        }

        switch all.count {
        case 0:
            throw DeviceSelectionError.noDevicesAvailable
        case 1:
            let device = all[0]
            print(colored("Auto-selected:", .cyan) + " \(device.displayName)")
            return device
        default:
            return try promptDeviceSelection(from: all)
        }
    }

    private func matchesHint(_ device: AvailableDevice, hint: String) -> Bool {
        switch device {
        case let .ios(d):
            d.udid == hint || d.name.lowercased() == hint.lowercased()
        case let .android(serial, name):
            serial == hint || name.lowercased() == hint.lowercased()
        }
    }
}

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

// MARK: - Interactive selection

private func promptiOSDeviceSelection(from devices: [BootedDevice]) throws -> BootedDevice {
    print("\nMultiple booted simulators found:")
    for (i, device) in devices.enumerated() {
        print("  \(i + 1)) \(device.displayName)")
    }
    print("")

    while true {
        print("Select a device [1-\(devices.count)]: ", terminator: "")
        fflush(stdout)

        guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) else {
            throw DeviceSelectionError.noBootedSimulators
        }
        guard let index = Int(line), index >= 1, index <= devices.count else {
            print("Invalid selection. Enter a number between 1 and \(devices.count).")
            continue
        }
        return devices[index - 1]
    }
}

private func promptDeviceSelection(from devices: [AvailableDevice]) throws -> AvailableDevice {
    print("\nAvailable devices:")
    for (i, device) in devices.enumerated() {
        print("  \(colored("\(i + 1))", .cyan)) \(device.displayName)")
    }
    print("")

    while true {
        print("Select a device [1-\(devices.count)]: ", terminator: "")
        fflush(stdout)

        guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) else {
            throw DeviceSelectionError.noDevicesAvailable
        }
        guard let index = Int(line), index >= 1, index <= devices.count else {
            print("Invalid selection. Enter a number between 1 and \(devices.count).")
            continue
        }
        return devices[index - 1]
    }
}
