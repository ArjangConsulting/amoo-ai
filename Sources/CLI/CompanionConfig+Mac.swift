import AmooCore
import Foundation
import IOSDriver

/// What differs when a companion config drives this Mac instead of an iOS simulator or device.
extension CompanionConfig {
    /// The port the macOS companion listens on unless told otherwise: below the iOS default, clear of
    /// Android's per-emulator block (22088…22103) and the per-simulator range (23000…23999).
    static let defaultMacPort = 22086

    /// Whether this drives this Mac's desktop through the macOS companion rather than an iOS device.
    var isMac: Bool {
        deviceUDID == MacHostBackend.deviceID
    }

    /// The Xcode scheme, and the UI-test bundle inside it, that this config builds and runs.
    var scheme: String {
        isMac ? "AmooCompanionMac" : "AmooCompanion"
    }

    var testBundle: String {
        isMac ? "AmooCompanionMacUITests" : "AmooCompanionUITests"
    }

    /// The SDK name Xcode puts in this config's `.xctestrun` file name.
    var productPlatform: String {
        if isMac {
            return "macosx"
        }
        return isPhysicalDevice ? "iphoneos" : "iphonesimulator"
    }
}

extension Platform {
    /// The port a companion for this platform listens on unless told otherwise.
    var defaultCompanionPort: Int {
        switch self {
        case .ios: CompanionConfig.defaultPort
        case .android: AndroidCompanionConfig.defaultPort
        case .macos: CompanionConfig.defaultMacPort
        }
    }
}
