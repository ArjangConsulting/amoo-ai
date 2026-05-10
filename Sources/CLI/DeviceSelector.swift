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

struct IOSSimulatorDevice: Equatable {
    let udid: String
    let name: String
    let osVersion: String

    var displayName: String {
        "\(name) [iOS \(osVersion)] (\(udid))"
    }
}

struct AndroidVirtualDevice: Equatable {
    let name: String

    var displayName: String { name }
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
    case noLaunchableDevices(Platform)
    case invalidSelection(String)
    case launchFailed(String)
    case startupTimedOut(String)

    var description: String {
        switch self {
        case .noBootedSimulators:
            return """
            No booted iOS simulator found.
            Boot one with:
              open -a Simulator
              xcrun simctl boot "<name-or-udid>"
            Then re-run amoo.
            """
        case .noDevicesAvailable:
            return """
            No iOS simulators or Android emulators/devices found.
            - iOS: open -a Simulator  (or xcrun simctl boot "<name-or-udid>")
            - Android: start an emulator in Android Studio or connect a device
            Then re-run amoo.
            """
        case let .noLaunchableDevices(platform):
            switch platform {
            case .ios:
                return """
                No available iOS simulators found.
                Install a simulator runtime in Xcode, then re-run amoo.
                """
            case .android:
                return """
                No Android virtual devices found.
                Create one in Android Studio Device Manager, then re-run amoo.
                """
            }
        case let .invalidSelection(input):
            return "Invalid selection '\(input)'. Enter a number from the list."
        case let .launchFailed(message):
            return "Failed to launch device: \(message)"
        case let .startupTimedOut(message):
            return message
        }
    }
}

protocol DeviceSelectionPrompting {
    func selectPlatform(from platforms: [Platform]) throws -> Platform
    func selectIOSSimulator(from devices: [IOSSimulatorDevice]) throws -> IOSSimulatorDevice
    func selectAndroidEmulator(from devices: [AndroidVirtualDevice]) throws -> AndroidVirtualDevice
}

struct ConsoleDeviceSelectionPrompter: DeviceSelectionPrompting {
    func selectPlatform(from platforms: [Platform]) throws -> Platform {
        try promptSelection(
            title: "\nNo running simulator/emulator found. Choose a platform:",
            prompt: "Select a platform",
            items: platforms,
            displayName: { platform in
                switch platform {
                case .ios: "iOS"
                case .android: "Android"
                }
            }
        )
    }

    func selectIOSSimulator(from devices: [IOSSimulatorDevice]) throws -> IOSSimulatorDevice {
        try promptSelection(
            title: "\nAvailable iOS simulators:",
            prompt: "Select a simulator",
            items: devices,
            displayName: \.displayName
        )
    }

    func selectAndroidEmulator(from devices: [AndroidVirtualDevice]) throws -> AndroidVirtualDevice {
        try promptSelection(
            title: "\nAvailable Android emulators:",
            prompt: "Select an emulator",
            items: devices,
            displayName: \.displayName
        )
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

    func listAvailableSimulators() async -> [IOSSimulatorDevice] {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        guard let json = try? await SimctlRunner(context: context).listDevices() else { return [] }
        return parseAvailableIOSSimulators(json: json)
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

    func listAvailableVirtualDevices() async -> [AndroidVirtualDevice] {
        guard let result = try? await processRunner.run(["emulator", "-list-avds"]) else { return [] }
        return parseAndroidVirtualDevices(output: result.stdout)
    }
}

// MARK: - Cross-platform PlatformDeviceSelector

struct PlatformDeviceSelector {
    private let processRunner: any ProcessRunner
    private let prompter: any DeviceSelectionPrompting

    init(
        processRunner: any ProcessRunner = SystemProcessRunner(),
        prompter: any DeviceSelectionPrompting = ConsoleDeviceSelectionPrompter()
    ) {
        self.processRunner = processRunner
        self.prompter = prompter
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
            return try await launchInteractiveDevice(platform: platform, iosSelector: iosSelector, androidSelector: androidSelector)
        case 1:
            let device = all[0]
            print(colored("Auto-selected:", .cyan) + " \(device.displayName)")
            return device
        default:
            return try promptDeviceSelection(from: all)
        }
    }

    private func launchInteractiveDevice(
        platform: Platform?,
        iosSelector: DeviceSelector,
        androidSelector: AndroidDeviceSelector
    ) async throws -> AvailableDevice {
        async let iosSimulatorsTask = platform == nil || platform == .ios
            ? iosSelector.listAvailableSimulators() : []
        async let androidVirtualDevicesTask = platform == nil || platform == .android
            ? androidSelector.listAvailableVirtualDevices() : []

        let iosSimulators = await iosSimulatorsTask
        let androidVirtualDevices = await androidVirtualDevicesTask

        let selectedPlatform: Platform
        if let platform {
            selectedPlatform = platform
        } else {
            let platforms = availablePlatforms(
                iosSimulators: iosSimulators,
                androidVirtualDevices: androidVirtualDevices
            )
            guard !platforms.isEmpty else {
                throw DeviceSelectionError.noDevicesAvailable
            }
            selectedPlatform = try prompter.selectPlatform(from: platforms)
        }

        switch selectedPlatform {
        case .ios:
            guard !iosSimulators.isEmpty else {
                throw DeviceSelectionError.noLaunchableDevices(.ios)
            }
            let simulator = iosSimulators.count == 1
                ? iosSimulators[0]
                : try prompter.selectIOSSimulator(from: iosSimulators)
            return .ios(try await bootIOSSimulator(simulator, selector: iosSelector))
        case .android:
            guard !androidVirtualDevices.isEmpty else {
                throw DeviceSelectionError.noLaunchableDevices(.android)
            }
            let virtualDevice = androidVirtualDevices.count == 1
                ? androidVirtualDevices[0]
                : try prompter.selectAndroidEmulator(from: androidVirtualDevices)
            return try await startAndroidEmulator(virtualDevice, selector: androidSelector)
        }
    }

    private func bootIOSSimulator(_ simulator: IOSSimulatorDevice, selector: DeviceSelector) async throws -> BootedDevice {
        _ = try? await processRunner.run(["open", "-a", "Simulator"])
        let bootResult = try await processRunner.run(["xcrun", "simctl", "boot", simulator.udid])
        guard bootResult.exitCode == 0 else {
            let message = bootResult.stderr.isEmpty ? bootResult.stdout : bootResult.stderr
            throw DeviceSelectionError.launchFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let bootedDevices = await selector.listBootedDevices()
            if let booted = bootedDevices.first(where: { $0.udid == simulator.udid }) {
                return booted
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        throw DeviceSelectionError.startupTimedOut(
            "Timed out waiting for iOS simulator \(simulator.name) to boot."
        )
    }

    private func startAndroidEmulator(
        _ virtualDevice: AndroidVirtualDevice,
        selector: AndroidDeviceSelector
    ) async throws -> AvailableDevice {
        try launchDetachedProcess(arguments: ["emulator", "-avd", virtualDevice.name])

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let onlineDevices = await selector.listOnlineDevices()
            if let device = onlineDevices.first {
                return .android(serial: device.serial, name: device.name)
            }
            try await Task.sleep(for: .seconds(2))
        }

        throw DeviceSelectionError.startupTimedOut(
            "Timed out waiting for Android emulator \(virtualDevice.name) to start."
        )
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

private func availablePlatforms(
    iosSimulators: [IOSSimulatorDevice],
    androidVirtualDevices: [AndroidVirtualDevice]
) -> [Platform] {
    var platforms: [Platform] = []
    if !iosSimulators.isEmpty {
        platforms.append(.ios)
    }
    if !androidVirtualDevices.isEmpty {
        platforms.append(.android)
    }
    return platforms
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

private func launchDetachedProcess(arguments: [String]) throws {
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

private func promptiOSDeviceSelection(from devices: [BootedDevice]) throws -> BootedDevice {
    try promptSelection(
        title: "\nMultiple booted simulators found:",
        prompt: "Select a device",
        items: devices,
        displayName: \.displayName,
        eofError: .noBootedSimulators
    )
}

private func promptDeviceSelection(from devices: [AvailableDevice]) throws -> AvailableDevice {
    try promptSelection(
        title: "\nAvailable devices:",
        prompt: "Select a device",
        items: devices,
        displayName: \.displayName,
        eofError: .noDevicesAvailable,
        colorNumbers: true
    )
}

private func promptSelection<T>(
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
