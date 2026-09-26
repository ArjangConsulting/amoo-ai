import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell

extension AndroidDeviceSelector {
    /// The AVD a running emulator was started from. `adb devices -l` only reports the model
    /// (`sdk_gphone64_arm64`), so without this an AVD-name hint can never match a running emulator.
    func runningAVDName(serial: String) async -> String? {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        guard serial.hasPrefix("emulator-"),
              let result = try? await Command("adb")
              .args(["-s", serial, "shell", "getprop", "ro.boot.qemu.avd_name"])
              .timeout(5)
              .run(in: context)
        else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Resolves an Android `device_hint` against running devices and installed AVDs.
    func resolve(hint: String) async -> AndroidHintResolution {
        let online = await listOnlineDevices()
        var avdNames: [String: String] = [:]
        for device in online where device.serial.hasPrefix("emulator-") {
            avdNames[device.serial] = await runningAVDName(serial: device.serial)
        }
        return await resolveAndroidHint(
            hint,
            online: online,
            runningAVDNames: avdNames,
            availableAVDs: listAvailableVirtualDevices().map(\.name)
        )
    }
}

enum AndroidHintResolution: Equatable {
    /// Already online: use it as-is.
    case running(serial: String, name: String)
    /// An installed AVD that is not running: boot it.
    case bootAVD(String)
    case unmatched
}

/// Matches a hint to an Android target. A physical device matches only by its exact serial:
/// a hint that names an AVD or a model must never resolve to a phone that happens to be
/// connected (a wireless-adb Pixel was being picked, or the AVD name was passed to
/// `adb -s` as though it were a serial).
func resolveAndroidHint(
    _ hint: String,
    online: [(serial: String, name: String)],
    runningAVDNames: [String: String],
    availableAVDs: [String]
) -> AndroidHintResolution {
    let lowered = hint.lowercased()
    if let exact = online.first(where: { $0.serial == hint }) {
        return .running(serial: exact.serial, name: runningAVDNames[exact.serial] ?? exact.name)
    }
    let emulators = online.filter { $0.serial.hasPrefix("emulator-") }
    if let byAVD = emulators.first(where: { runningAVDNames[$0.serial]?.lowercased() == lowered }) {
        return .running(serial: byAVD.serial, name: runningAVDNames[byAVD.serial] ?? byAVD.name)
    }
    if let byModel = emulators.first(where: { $0.name.lowercased() == lowered }) {
        return .running(serial: byModel.serial, name: byModel.name)
    }
    if let avd = availableAVDs.first(where: { $0.lowercased() == lowered }) {
        return .bootAVD(avd)
    }
    return .unmatched
}

/// `amoo companion … --platform android --device <AVD name>` targets that AVD's emulator —
/// booting it for install/start/warm — instead of passing the name to `adb -s` as a serial.
func resolvingAndroidCompanionDevice(
    _ options: CompanionCommandOptions,
    selector: AndroidDeviceSelector = AndroidDeviceSelector()
) async throws -> CompanionCommandOptions {
    guard options.platform == .android, options.deviceID != "booted" else { return options }
    var resolved = options
    switch await selector.resolve(hint: options.deviceID) {
    case let .running(serial, _):
        resolved.deviceID = serial
    case .bootAVD where options.action == .status:
        return options // `status` never boots; it reports not_started.
    case let .bootAVD(avd):
        resolved.deviceID = try await selector.bootVirtualDevice(name: avd).id
    case .unmatched:
        throw DeviceSelectionError.launchFailed(
            "No running Android emulator/device or AVD matches '\(options.deviceID)'."
                + " Pass an adb serial (emulator-5554) or an AVD name from `emulator -list-avds`."
        )
    }
    return resolved
}
