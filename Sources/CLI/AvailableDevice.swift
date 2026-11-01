import AmooCore
import Foundation
import IOSDriver

/// A device a session can run on, as device selection found it.
enum AvailableDevice {
    case ios(BootedDevice)
    case android(serial: String, name: String)
    /// This Mac's own desktop. Only ever selected when the caller asks for `macos` explicitly.
    case macos(name: String)

    var platform: Platform {
        switch self {
        case .ios: .ios
        case .android: .android
        case .macos: .macos
        }
    }

    var displayName: String {
        switch self {
        case let .ios(device):
            "[iOS]     \(device.displayName)"
        case let .android(serial, name):
            "[Android] \(name) (\(serial))"
        case let .macos(name):
            "[macOS]   \(name) (this Mac)"
        }
    }

    /// Simulator UDID, adb serial, or `mac`.
    var deviceID: String {
        switch self {
        case let .ios(device): device.udid
        case let .android(serial, _): serial
        case .macos: MacHostBackend.deviceID
        }
    }

    /// Whether this is real hardware rather than a simulator/emulator. Android emulator
    /// serials are always `emulator-<port>`; anything else is a physical device's serial.
    var isPhysicalDevice: Bool {
        switch self {
        case let .ios(device): device.isPhysicalDevice
        case let .android(serial, _): !serial.hasPrefix("emulator-")
        case .macos: true
        }
    }
}
