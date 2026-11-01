import AmooCore
import Foundation
import IOSDriver

extension PlatformDeviceSelector {
    /// This Mac, when `hint` is empty or names it: `mac`, `macos`, its device id or its computer name.
    ///
    /// The Mac is reachable only through an explicit `macos` platform, never a hint-less pick across
    /// platforms: driving it moves the user's own pointer and clicks in their own apps.
    static func macDevice(hint: String?) throws -> AvailableDevice {
        let name = MacHostBackend.currentDeviceInfo().name
        guard let hint = hint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty else {
            return .macos(name: name)
        }
        let accepted = ["mac", "macos", "this mac", MacHostBackend.deviceID, name.lowercased()]
        guard accepted.contains(hint.lowercased()) else {
            throw DeviceSelectionError.launchFailed(
                "'\(hint)' is not this Mac. On macOS amoo drives only the Mac it runs on;"
                    + " omit device_hint or pass 'mac'."
            )
        }
        return .macos(name: name)
    }
}
