import AmooCore
import AmooLogging
import Foundation

public extension AndroidDriver {
    func setPosture(_ posture: DevicePosture) async throws -> DevicePosture {
        let logger = AmooLogger.forType(Self.self)
        logger.info("Changing emulator posture", context: "action=setPosture state=\(posture.rawValue)")
        do {
            try await requireEmulator(capability: "device.posture")
            let identifier = switch posture {
            case .closed: 1
            case .halfOpened: 2
            case .opened: 3
            }
            try await emulatorCommand(["posture", String(identifier)])
            let deadline = ContinuousClock.now + .seconds(5)
            var observed = "unavailable"
            repeat {
                try Task.checkCancellation()
                let result = try await adb.run(
                    adbArgs() + ["shell", "cmd", "device_state", "state"], timeoutSeconds: 2
                )
                observed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.committedPosture(observed) == posture {
                    logger.info("Emulator posture verified", context: "action=setPosture state=\(posture.rawValue)")
                    return posture
                }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            throw AmooError.commandFailed(command: "setPosture", output: "Posture did not settle: \(observed)")
        } catch {
            logger.error(
                "Emulator posture failed",
                error: error,
                context: "action=setPosture state=\(posture.rawValue)"
            )
            throw error
        }
    }

    func setDisplayPreset(_ preset: DisplayPreset) async throws -> DeviceDisplayConfiguration {
        let logger = AmooLogger.forType(Self.self)
        logger.info("Changing emulator display", context: "action=setDisplayPreset state=\(preset.rawValue)")
        do {
            try await requireEmulator(capability: "device.displayPreset")
            let identifier = switch preset {
            case .phone: 0
            case .unfolded: 1
            case .tablet: 2
            }
            let expected = try await configuredDisplayPreset(identifier: identifier)
            let observed = try await applyDisplayPreset(identifier: identifier, expected: expected)
            logger.info("Emulator display verified", context: "action=setDisplayPreset state=\(preset.rawValue)")
            return observed
        } catch {
            logger.error(
                "Emulator display failed",
                error: error,
                context: "action=setDisplayPreset state=\(preset.rawValue)"
            )
            throw error
        }
    }
}

extension AndroidDriver {
    private func applyDisplayPreset(
        identifier: Int,
        expected: DeviceDisplayConfiguration
    ) async throws -> DeviceDisplayConfiguration {
        let deadline = ContinuousClock.now + .seconds(5)
        var nextDispatch = ContinuousClock.now
        var lastRead = "unavailable"
        repeat {
            try Task.checkCancellation()
            if ContinuousClock.now >= nextDispatch {
                try await emulatorCommand(["resize-display", String(identifier)])
                nextDispatch = ContinuousClock.now + .seconds(1)
            }
            do {
                let display = try await adb.run(adbArgs() + ["shell", "dumpsys", "display"], timeoutSeconds: 2)
                if let observed = Self.activeDisplayConfiguration(display.stdout) {
                    lastRead = "\(observed.widthPixels)x\(observed.heightPixels) at \(observed.densityDPI) dpi"
                    if observed.densityDPI == expected.densityDPI,
                       Set([observed.widthPixels, observed.heightPixels]) ==
                       Set([expected.widthPixels, expected.heightPixels]) {
                        return observed
                    }
                }
            } catch {
                try Task.checkCancellation()
                lastRead = String(describing: error)
                AmooLogger.forType(Self.self).error(
                    "Display read-back failed", error: error, context: "action=setDisplayPreset state=verifying"
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw AmooError.commandFailed(
            command: "setDisplayPreset",
            output: "Display did not reach \(expected.widthPixels)x\(expected.heightPixels)"
                + " at \(expected.densityDPI) dpi. Last read: \(lastRead)"
        )
    }

    private func configuredDisplayPreset(identifier: Int) async throws -> DeviceDisplayConfiguration {
        let directory: URL
        if let registration = try await emulator.runningEmulators().first(where: { $0.serial == activeSerial }) {
            directory = registration.directory
        } else {
            let result = try await adb.run(adbArgs() + ["emu", "avd", "path"], timeoutSeconds: 5)
            guard let path = result.stdout.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("/") }) else {
                throw AmooError.unsupportedCapability(
                    key: "device.displayPreset", reason: "Emulator did not report an AVD path."
                )
            }
            directory = URL(fileURLWithPath: String(path).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let runtimeConfig = directory.appendingPathComponent("hardware-qemu.ini")
        let configURL = FileManager.default.fileExists(atPath: runtimeConfig.path)
            ? runtimeConfig : directory.appendingPathComponent("config.ini")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        guard let expected = Self.displayPresetConfiguration(config, identifier: identifier) else {
            throw AmooError.unsupportedCapability(
                key: "device.displayPreset", reason: "AVD does not configure this resizable display preset."
            )
        }
        return expected
    }

    private func requireEmulator(capability: String) async throws {
        if activeSerial == nil {
            let devices = try await connectedDevices().filter { $0.state == "device" }
            guard devices.count == 1, let device = devices.first else {
                throw AmooError.deviceNotFound("Select one Android emulator explicitly.")
            }
            resolvedSerial = device.serial
        }
        guard activeSerial?.hasPrefix("emulator-") == true else {
            throw AmooError.unsupportedCapability(key: capability, reason: "Requires an Android emulator.")
        }
    }

    private func emulatorCommand(_ arguments: [String]) async throws {
        let result = try await adb.run(adbArgs() + ["emu"] + arguments, timeoutSeconds: 3)
        let output = result.stdout + result.stderr
        guard result.exitCode == 0, !output.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("KO")
        }), output.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "OK"
        }) else {
            throw AmooError.commandFailed(command: "adb emu \(arguments.joined(separator: " "))", output: output)
        }
    }

    static func committedPosture(_ output: String) -> DevicePosture? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Committed state:")
        }) else { return nil }
        if line.contains("name='CLOSED'") {
            return .closed
        }
        if line.contains("name='HALF_OPENED'") {
            return .halfOpened
        }
        if line.contains("name='OPENED'") {
            return .opened
        }
        return nil
    }

    static func displayPresetConfiguration(_ output: String, identifier: Int) -> DeviceDisplayConfiguration? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: {
            $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "hw.resizable.configs"
        }), let configurations = line.split(separator: "=", maxSplits: 1).last else { return nil }
        for entry in configurations.split(separator: ",") {
            let values = entry.trimmingCharacters(in: .whitespaces).split(separator: "-").suffix(4)
                .compactMap { Int($0) }
            if values.count == 4, values[0] == identifier, values.dropFirst().allSatisfy({ $0 > 0 }) {
                return DeviceDisplayConfiguration(
                    widthPixels: values[1],
                    heightPixels: values[2],
                    densityDPI: values[3]
                )
            }
        }
        return nil
    }

    static func activeDisplayConfiguration(_ output: String) -> DeviceDisplayConfiguration? {
        let lines = output.split(whereSeparator: \.isNewline).filter { $0.contains("displayId 0,") }
        guard let line = lines.first(where: { $0.contains("mOverrideDisplayInfo=DisplayInfo{") }) ??
            lines.first(where: { $0.contains("mBaseDisplayInfo=DisplayInfo{") }) else { return nil }
        let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let dimensions = fields.first(where: { $0.hasPrefix("real ") })?.split(separator: " "),
              dimensions.count == 4,
              let width = Int(dimensions[1]), let height = Int(dimensions[3]),
              let density = fields.first(where: { $0.hasPrefix("density ") })?.split(separator: " "),
              density.count >= 2, let dpi = Int(density[1].prefix(while: \.isNumber)),
              width > 0, height > 0, dpi > 0 else { return nil }
        return DeviceDisplayConfiguration(widthPixels: width, heightPixels: height, densityDPI: dpi)
    }
}
