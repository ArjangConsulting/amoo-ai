import Foundation
import MobileTestingCore
import ProcessRunner

// MARK: - Types

struct BootedDevice {
    let udid: String
    let name: String
    let osVersion: String

    var displayName: String {
        "\(name) [iOS \(osVersion)] (\(udid))"
    }
}

enum DeviceSelectionError: Error, CustomStringConvertible {
    case noBootedSimulators
    case invalidSelection(String)

    var description: String {
        switch self {
        case .noBootedSimulators:
            """
            No booted iOS simulator found.
            Boot one with:
              open -a Simulator
              xcrun simctl boot "<name-or-udid>"
            Then re-run mobile-testing.
            """
        case let .invalidSelection(input):
            "Invalid selection '\(input)'. Enter a number from the list."
        }
    }
}

// MARK: - DeviceSelector

struct DeviceSelector {
    private let processRunner: any ProcessRunner

    init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func selectDevice(hint: String? = nil) async throws -> BootedDevice {
        let result = try await processRunner.run(["xcrun", "simctl", "list", "devices", "available", "-j"])
        let booted = parseBootedDevices(json: result.stdout)

        if let hint {
            if let match = booted.first(where: { $0.udid == hint || $0.name.lowercased() == hint.lowercased() }) {
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
            return try promptDeviceSelection(from: booted)
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
        let osVersion = runtime
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

// MARK: - Interactive selection

private func promptDeviceSelection(from devices: [BootedDevice]) throws -> BootedDevice {
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
