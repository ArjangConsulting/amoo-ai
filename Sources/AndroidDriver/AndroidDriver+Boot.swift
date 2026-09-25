import AmooCore
import Foundation
import ProcessRunner

/// Device selection and emulator launch for `device_boot`.
public extension AndroidDriver {
    func boot() async throws {
        try await adb.startServer()
        let devices = try await connectedDevices()
        let online = devices.filter { $0.state == "device" }
        if let requestedDeviceID {
            if let connected = online.first(where: { $0.serial == requestedDeviceID }) {
                resolvedSerial = connected.serial
                return
            }
            // An AVD name whose emulator is already up: reuse it. Launching a second instance of
            // the same AVD fails on its lock file.
            if !requestedDeviceID.hasPrefix("emulator-") {
                for device in online where device.serial.hasPrefix("emulator-") {
                    if await runningAVDName(serial: device.serial) == requestedDeviceID {
                        resolvedSerial = device.serial
                        return
                    }
                }
            }
        } else {
            // With no device requested, only an emulator may be picked. A physical phone
            // (often attached over wireless adb) is never driven unless named by serial.
            if let emulator = online.first(where: { $0.serial.hasPrefix("emulator-") }) {
                resolvedSerial = emulator.serial
                return
            }
            if !online.isEmpty {
                throw AmooError.commandFailed(
                    command: "device_boot",
                    output: "Only physical Android devices are connected ("
                        + online.map(\.serial).joined(separator: ", ")
                        + "). amoo never auto-selects a physical device: pass its serial explicitly,"
                        + " or an AVD name to boot an emulator."
                )
            }
        }

        guard let avdName = requestedDeviceID, !avdName.hasPrefix("emulator-") else {
            throw AmooError.commandFailed(
                command: "device_boot",
                output: "Requested Android device is not connected: \(requestedDeviceID ?? "default")"
            )
        }
        let port = nextEmulatorPort(devices: devices)
        try await emulator.launch(avdName: avdName, port: port)
        let launchedSerial = "emulator-\(port)"
        try await waitForBoot(serial: launchedSerial, timeoutSeconds: 120)
        resolvedSerial = launchedSerial
    }
}
