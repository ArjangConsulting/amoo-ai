import AmooCore
import Foundation
import ProcessRunner

/// Device selection and emulator launch for `device_boot`.
public extension AndroidDriver {
    func boot() async throws {
        try await adb.startServer()
        var devices = try await connectedDevices()
        if try await resolveRegisteredEmulator(devices: &devices) {
            return
        }
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
        let launch = try await emulator.launchProcess(avdName: avdName, port: port)
        let launchedSerial = "emulator-\(port)"
        try await waitForBoot(serial: launchedSerial, timeoutSeconds: 120, launch: launch)
        resolvedSerial = launchedSerial
    }
}

extension AndroidDriver {
    private func resolveRegisteredEmulator(devices: inout [(serial: String, state: String)]) async throws -> Bool {
        guard let registration = try await requestedRegistration() else { return false }
        if devices.contains(where: { $0.serial == registration.serial }) {
            guard !emulator.coldBootRequested else {
                throw AmooError.commandFailed(
                    command: "device_boot",
                    output: "AVD is still running; verify shutdown before cold boot."
                )
            }
            if !devices.contains(where: { $0.serial == registration.serial && $0.state == "device" }) {
                try await waitForBoot(serial: registration.serial, timeoutSeconds: 120)
            }
            resolvedSerial = registration.serial
            return true
        }
        try await waitForRegisteredEmulatorExit(registration)
        devices = try await connectedDevices()
        return false
    }

    private func requestedRegistration() async throws -> AndroidEmulatorRegistration? {
        guard let avd = requestedDeviceID, !avd.hasPrefix("emulator-") else { return nil }
        return try await emulator.runningEmulators().first { $0.avdID == avd }
    }

    private func waitForRegisteredEmulatorExit(_ registration: AndroidEmulatorRegistration) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        repeat {
            try Task.checkCancellation()
            let registrations = try await emulator.runningEmulators()
            if !registrations.contains(where: { $0.pid == registration.pid }) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw AmooError.commandFailed(
            command: "device_boot",
            output: "AVD \(registration.avdID) is still running as \(registration.serial) (pid \(registration.pid))"
                + " but is unavailable through ADB. Stop that emulator before retrying; no duplicate was launched."
        )
    }
}
