import AmooCore
import Foundation
import ProcessRunner

/// ADB plumbing: device enumeration, serial resolution, and boot waiting.
///
/// Split out of `AndroidDriver` itself so the actor body stays under the type-length limit — the
/// driver's own file is the `PlatformDriver` surface, this one is how it talks to `adb`.
extension AndroidDriver {
    func adbArgs() -> [String] {
        if let serial = activeSerial {
            return ["-s", serial]
        }
        return []
    }

    var activeSerial: String? {
        resolvedSerial ?? requestedDeviceID
    }

    func connectedDevices() async throws -> [(serial: String, state: String)] {
        try await adb.listDevices().split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: \Character.isWhitespace)
            guard columns.count >= 2, columns[0] != "List" else { return nil }
            return (String(columns[0]), String(columns[1]))
        }
    }

    /// The AVD a running emulator was started from, via `ro.boot.qemu.avd_name`.
    func runningAVDName(serial: String) async -> String? {
        guard let result = try? await adb.run(
            ["-s", serial, "shell", "getprop", "ro.boot.qemu.avd_name"],
            timeoutSeconds: 5
        ), result.exitCode == 0 else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func nextEmulatorPort(devices: [(serial: String, state: String)]) -> Int {
        let used: Set<Int> = Set(devices.compactMap { device -> Int? in
            guard device.serial.hasPrefix("emulator-") else { return nil }
            return Int(device.serial.dropFirst("emulator-".count))
        })
        return stride(from: 5554, through: 5680, by: 2).first(where: { !used.contains($0) }) ?? 5554
    }

    /// Best-effort screen power/lock state via `dumpsys`. Neither `power` nor `window`'s field
    /// names are a stable public API across Android versions, so this checks several known
    /// spellings rather than one exact match. Unknown power output stays unknown instead of
    /// falsely reporting that the screen is off. Each probe has a short deadline.
    func androidScreenState() async throws -> ScreenPowerState? {
        guard let powerDump = try? await adb.run(adbArgs() + ["shell", "dumpsys", "power"], timeoutSeconds: 2) else {
            return nil
        }
        if powerDump.stdout.contains("mWakefulness=Asleep") || powerDump.stdout.contains("mWakefulness=Dozing") {
            return .off
        }
        guard powerDump.stdout.contains("mWakefulness=Awake") else { return nil }
        guard let windowDump = try? await adb.run(adbArgs() + ["shell", "dumpsys", "window"], timeoutSeconds: 2) else {
            return .on
        }
        let lockedMarkers = [
            "mDreamingLockscreen=true",
            "isStatusBarKeyguard=true",
            "mKeyguardShowing=true",
            "isKeyguardShowingAndNotOccluded=true"
        ]
        return lockedMarkers.contains { windowDump.stdout.contains($0) } ? .locked : .on
    }

    /// Waits for `serial` to finish booting. When `launch` is given, an emulator process that dies
    /// first fails the wait at once — with its exit code and log — instead of timing out.
    func waitForBoot(serial: String, timeoutSeconds: Int, launch: EmulatorLaunch? = nil) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        var launcherExitedAt: Date?
        while Date() < deadline {
            if let launch, case let .exited(exitCode) = launch.liveness() {
                // A launcher that exited 0 may have handed off to a sibling process still
                // registering with adb, so give that a grace period; a crash fails immediately.
                let exitedAt = launcherExitedAt ?? Date()
                launcherExitedAt = exitedAt
                let registered = try await connectedDevices().contains { $0.serial == serial }
                if !registered, exitCode != 0 || Date().timeIntervalSince(exitedAt) > 10 {
                    throw AmooError.commandFailed(
                        command: "emulator -avd \(requestedDeviceID ?? serial) -port \(serial.dropFirst("emulator-".count))",
                        output: "The emulator exited before it booted"
                            + (exitCode.map { " (exit code \($0))" } ?? "")
                            + ". Log: \(launch.logPath ?? "none")\n\(launch.logTail())"
                    )
                }
            }
            let devices = try await connectedDevices()
            if devices.contains(where: { $0.serial == serial && $0.state == "device" }) {
                let result = try await adb.run(["-s", serial, "shell", "getprop", "sys.boot_completed"])
                if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                    return
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        if let launch {
            // Still alive but never reached `device`: say where to look instead of only timing out.
            let tail = launch.logTail(lines: 10)
            if !tail.isEmpty {
                throw AmooError.commandFailed(
                    command: "boot Android emulator \(requestedDeviceID ?? serial)",
                    output: "Timed out after \(timeoutSeconds)s; the emulator process is still running"
                        + " (pid \(launch.pid)). Log: \(launch.logPath ?? "none")\n\(tail)"
                )
            }
        }
        throw AmooError.timeout(
            operation: "boot Android emulator \(requestedDeviceID ?? serial)",
            duration: Duration(milliseconds: timeoutSeconds * 1000)
        )
    }
}
