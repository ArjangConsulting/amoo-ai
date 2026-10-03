import Foundation

extension PlatformDeviceSelector {
    func matchesHint(_ device: AvailableDevice, hint: String) -> Bool {
        switch device {
        case let .ios(iosDevice):
            iosDevice.udid == hint || iosDevice.name.lowercased() == hint.lowercased()
        case let .android(serial, name):
            // Model names only identify emulators; a phone matches by exact serial alone.
            serial == hint || (serial.hasPrefix("emulator-") && name.lowercased() == hint.lowercased())
        }
    }
}
