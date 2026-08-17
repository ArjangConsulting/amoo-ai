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

    func nextEmulatorPort(devices: [(serial: String, state: String)]) -> Int {
        let used: Set<Int> = Set(devices.compactMap { device -> Int? in
            guard device.serial.hasPrefix("emulator-") else { return nil }
            return Int(device.serial.dropFirst("emulator-".count))
        })
        return stride(from: 5554, through: 5680, by: 2).first(where: { !used.contains($0) }) ?? 5554
    }

    func waitForBoot(serial: String, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            let devices = try await connectedDevices()
            if devices.contains(where: { $0.serial == serial && $0.state == "device" }) {
                let result = try await adb.run(["-s", serial, "shell", "getprop", "sys.boot_completed"])
                if result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                    return
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw AmooError.timeout(
            operation: "boot Android emulator \(requestedDeviceID ?? serial)",
            duration: Duration(milliseconds: timeoutSeconds * 1000)
        )
    }
}
