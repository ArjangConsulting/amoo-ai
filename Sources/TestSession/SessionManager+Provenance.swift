import AmooCore
import Foundation

extension SessionManager {
    static func sessionProvenance(
        driver: any PlatformDriver,
        arguments: [String],
        environment: [String: String]
    ) async -> [String: String] {
        let device = try? await OperationDeadline.read(until: .now + .seconds(3)) {
            try await driver.deviceInfo()
        }
        var locale = environment["LANG"] ?? "unavailable: device locale is not exposed by the companion"
        if let index = arguments.firstIndex(of: "-AppleLocale"), arguments.indices.contains(index + 1) {
            locale = arguments[index + 1]
        }
        return [
            "device_os": device?.osVersion ?? "unavailable: device info read failed",
            "locale": locale,
            "locale_source": locale.hasPrefix("unavailable:") ? "unavailable" : "launch configuration",
            "companion_fingerprint": "unavailable: companion protocol does not expose a build fingerprint"
        ]
    }
}
