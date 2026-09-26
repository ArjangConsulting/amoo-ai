import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell

// MARK: - Types

struct BootedDevice {
    let udid: String
    let name: String
    let osVersion: String
    /// Whether this is real hardware rather than a simulator. Determines which host
    /// toolchain drives it (`devicectl` vs `simctl`) and whether a USB tunnel is needed
    /// to reach the companion.
    var isPhysicalDevice: Bool = false

    var displayName: String {
        let kind = isPhysicalDevice ? "device" : "sim"
        return "\(name) [iOS \(osVersion), \(kind)] (\(udid))"
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

    var displayName: String {
        name
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

    /// Simulator UDID or adb serial.
    var deviceID: String {
        switch self {
        case let .ios(device): device.udid
        case let .android(serial, _): serial
        }
    }

    /// Whether this is real hardware rather than a simulator/emulator. Android emulator
    /// serials are always `emulator-<port>`; anything else is a physical device's serial.
    var isPhysicalDevice: Bool {
        switch self {
        case let .ios(device): device.isPhysicalDevice
        case let .android(serial, _): !serial.hasPrefix("emulator-")
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
            """
            No booted iOS simulator or connected device found.
            Boot a simulator with:
              open -a Simulator
              xcrun simctl boot "<name-or-udid>"
            Or connect a physical device and check it is paired and trusted:
              xcrun devicectl list devices
            Physical devices also need `iproxy` (brew install libimobiledevice) to reach \
            the companion, and the XCUITest runner must be signed with a provisioning \
            profile valid for that device.
            Then re-run amoo.
            """
        case .noDevicesAvailable:
            """
            No iOS simulators or Android emulators/devices found.
            - iOS: open -a Simulator  (or xcrun simctl boot "<name-or-udid>")
            - Android: start an emulator in Android Studio or connect a device
            Then re-run amoo.
            """
        case let .noLaunchableDevices(platform):
            switch platform {
            case .ios:
                """
                No available iOS simulators found.
                Install a simulator runtime in Xcode, then re-run amoo.
                """
            case .android:
                """
                No Android virtual devices found.
                Create one in Android Studio Device Manager, then re-run amoo.
                """
            }
        case let .invalidSelection(input):
            "Invalid selection '\(input)'. Enter a number from the list."
        case let .launchFailed(message):
            "Failed to launch device: \(message)"
        case let .startupTimedOut(message):
            message
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
        let booted = await listBootedDevices()

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
            guard isInteractiveStdin() else {
                return autoSelectDevice(from: booted, displayName: \.displayName) { $0.isPhysicalDevice }
            }
            return try promptiOSDeviceSelection(from: booted)
        }
    }

    /// Booted simulators plus connected physical devices, since both are drivable targets.
    func listBootedDevices() async -> [BootedDevice] {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        let simulators = await (try? SimctlRunner(context: context).listDevices())
            .map(parseBootedDevices(json:)) ?? []
        return await simulators + listPhysicalDevices()
    }

    /// Physical iOS devices currently connected and paired, via `devicectl`.
    ///
    /// Returns empty rather than throwing when `devicectl` is unavailable — an older
    /// Xcode shouldn't stop simulator workflows from listing.
    func listPhysicalDevices() async -> [BootedDevice] {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        guard let json = try? await DeviceCtlRunner(context: context).listDevices() else { return [] }
        return parseConnectedIOSDevices(json: json)
    }

    /// Whether `deviceID` names a connected physical device rather than a simulator.
    func isPhysicalDevice(deviceID: String) async -> Bool {
        guard deviceID != "booted" else { return false }
        return await listPhysicalDevices().contains {
            $0.udid == deviceID || $0.name.lowercased() == deviceID.lowercased()
        }
    }

    func listAvailableSimulators() async -> [IOSSimulatorDevice] {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        guard let json = try? await SimctlRunner(context: context).listDevices() else { return [] }
        return parseAvailableIOSSimulators(json: json)
    }
}

// MARK: - Android device listing

struct AndroidDeviceSelector {
    let processRunner: any ProcessRunner

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
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        guard let result = try? await Command("emulator").args(["-list-avds"]).timeout(10).run(in: context)
        else { return [] }
        return parseAndroidVirtualDevices(output: result.stdout)
    }
}

// MARK: - Cross-platform PlatformDeviceSelector

struct PlatformDeviceSelector {
    private let processRunner: any ProcessRunner
    private let prompter: any DeviceSelectionPrompting
    private let interactive: Bool
    private let leaseStore: DeviceLeaseStore

    init(
        processRunner: any ProcessRunner = SystemProcessRunner(),
        prompter: any DeviceSelectionPrompting = ConsoleDeviceSelectionPrompter(),
        interactive: Bool = isInteractiveStdin(),
        leaseStore: DeviceLeaseStore = DeviceLeaseStore()
    ) {
        self.processRunner = processRunner
        self.prompter = prompter
        self.interactive = interactive
        self.leaseStore = leaseStore
    }

    /// Lists all available iOS simulators and Android devices/emulators concurrently,
    /// then prompts the user when more than one is found.
    func selectDevice(hint: String? = nil, platform: Platform? = nil) async throws -> AvailableDevice {
        let iosSelector = DeviceSelector(processRunner: processRunner)
        let androidSelector = AndroidDeviceSelector(processRunner: processRunner)

        async let iosDevices = platform == .android ? [] : iosSelector.listBootedDevices()
        async let androidDevices = platform == .ios ? [] : androidSelector.listOnlineDevices()

        var all: [AvailableDevice] = []
        let ios = await iosDevices
        let android = await androidDevices

        if platform == nil || platform == .ios {
            all += ios.map { .ios($0) }
        }
        if platform == nil || platform == .android {
            all += android.map { .android(serial: $0.serial, name: $0.name) }
        }

        if let hint {
            return try await resolveHint(hint, platform: platform, among: all, androidSelector: androidSelector)
        }

        all = try autoSelectable(all)

        switch all.count {
        case 0:
            return try await launchInteractiveDevice(
                platform: platform,
                iosSelector: iosSelector,
                androidSelector: androidSelector
            )
        case 1:
            let device = all[0]
            print(colored("Auto-selected:", .cyan) + " \(device.displayName)")
            return device
        default:
            guard interactive else {
                return autoSelectDevice(from: all, displayName: \.displayName) { $0.isPhysicalDevice }
            }
            return try promptDeviceSelection(from: all)
        }
    }

    /// Candidates a hint-less pick may land on: never a device another session leased, and —
    /// with nobody at the keyboard to confirm — never a physical device.
    private func autoSelectable(_ candidates: [AvailableDevice]) throws -> [AvailableDevice] {
        var all = candidates
        // Without a hint, never auto-pick a device another session holds a lease on.
        let presented = presentedLease(flag: nil)
        let unleased = all.filter {
            if case .leasedByOther = leaseStore.access(deviceID: $0.deviceID, lease: presented) {
                return false
            }
            return true
        }
        if !unleased.isEmpty {
            all = unleased
        }
        // Nor, without someone at the keyboard to confirm, a physical device.
        if !interactive, !all.isEmpty {
            let virtual = all.filter { !$0.isPhysicalDevice }
            guard !virtual.isEmpty else {
                throw DeviceSelectionError.launchFailed(
                    "Only physical devices are available (" + all.map(\.displayName).joined(separator: ", ")
                        + "). amoo never auto-selects a physical device; pass device_hint=<udid|serial> to use one."
                )
            }
            all = virtual
        }
        return all
    }

    private func resolveHint(
        _ hint: String,
        platform: Platform?,
        among all: [AvailableDevice],
        androidSelector: AndroidDeviceSelector
    ) async throws -> AvailableDevice {
        if let match = all.first(where: { matchesHint($0, hint: hint) }) {
            return match
        }
        if platform != .ios {
            switch await androidSelector.resolve(hint: hint) {
            case let .running(serial, name):
                return .android(serial: serial, name: name)
            case let .bootAVD(avd):
                return try await startAndroidEmulator(AndroidVirtualDevice(name: avd), selector: androidSelector)
            case .unmatched where platform == .android:
                // Never pass an unknown hint through as an `adb -s` serial.
                throw DeviceSelectionError.launchFailed(
                    "No running Android emulator/device or AVD matches '\(hint)'."
                        + " Pass an adb serial (emulator-5554) or an AVD name from `emulator -list-avds`."
                )
            case .unmatched:
                break
            }
        }
        // Hint provided but not listed — allow the caller to continue if a companion is up.
        return .ios(BootedDevice(udid: hint, name: hint, osVersion: "unknown"))
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
            return try await .ios(bootIOSSimulator(simulator, selector: iosSelector))
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

    private func bootIOSSimulator(
        _ simulator: IOSSimulatorDevice,
        selector: DeviceSelector
    ) async throws -> BootedDevice {
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
        let device = try await selector.bootVirtualDevice(name: virtualDevice.name)
        return .android(serial: device.id, name: device.name)
    }

    private func matchesHint(_ device: AvailableDevice, hint: String) -> Bool {
        switch device {
        case let .ios(iosDevice):
            iosDevice.udid == hint || iosDevice.name.lowercased() == hint.lowercased()
        case let .android(serial, name):
            // Model names only identify emulators; a phone matches by exact serial alone.
            serial == hint || (serial.hasPrefix("emulator-") && name.lowercased() == hint.lowercased())
        }
    }
}

func availablePlatforms(
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
