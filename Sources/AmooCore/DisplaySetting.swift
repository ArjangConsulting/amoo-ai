import Foundation

/// A system display setting an accessibility check varies, and must put back afterwards.
///
/// Values are strings in the platform's own spelling, because the two platforms do not share a
/// scale: text size is a content-size category on iOS (`large`, `accessibility-extra-large`) and a
/// font-scale factor on Android (`1.0`, `1.3`). Appearance is `light` or `dark` (Android also
/// reports `auto`), and increased contrast is `enabled` or `disabled`.
public enum DisplaySetting: String, Sendable, Equatable, CaseIterable, Codable {
    case appearance
    case textSize = "text_size"
    case increaseContrast = "increase_contrast"

    /// The value a factory-default device reports, which a check uses as its baseline.
    public func defaultValue(for platform: Platform) -> String {
        switch self {
        case .appearance: "light"
        case .textSize: platform == .android ? "1.0" : "large"
        case .increaseContrast: "disabled"
        }
    }

    /// The value a check switches to: dark mode, the largest text the platform offers, contrast on.
    ///
    /// Android's settings stop at a 200% font scale; iOS stops at its fifth accessibility size.
    public func accessibilityValue(for platform: Platform) -> String {
        switch self {
        case .appearance: "dark"
        case .textSize: platform == .android ? "2.0" : "accessibility-extra-extra-extra-large"
        case .increaseContrast: "enabled"
        }
    }

    /// The iOS content-size categories, smallest first, as `simctl ui content_size` spells them.
    public static let iosTextSizes = [
        "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large",
        "extra-extra-extra-large", "accessibility-medium", "accessibility-large",
        "accessibility-extra-large", "accessibility-extra-extra-large",
        "accessibility-extra-extra-extra-large"
    ]

    /// The Android font scales amoo accepts. Beyond 200% the system clamps or renders unusably.
    public static let androidFontScaleRange = 0.5 ... 2.0

    /// `value` in the spelling the device reports, or nil when the platform does not accept it.
    public func canonicalValue(_ value: String, for platform: Platform) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        switch self {
        case .appearance:
            let accepted = platform == .android ? ["light", "dark", "auto"] : ["light", "dark"]
            return accepted.contains(trimmed) ? trimmed : nil
        case .increaseContrast:
            return ["enabled", "disabled"].contains(trimmed) ? trimmed : nil
        case .textSize:
            guard platform == .android else {
                return Self.iosTextSizes.contains(trimmed) ? trimmed : nil
            }
            guard let scale = Double(trimmed), Self.androidFontScaleRange.contains(scale) else { return nil }
            return String(scale)
        }
    }
}

/// Reads and changes ``DisplaySetting``s. A device that cannot read a setting must not change it on
/// behalf of a check, because the check has to put the original back.
public protocol DisplaySettingConfigurator: Sendable {
    /// The device's current value for `setting`, in the platform's own spelling. A device that cannot
    /// report it throws `unsupportedCapability`, so a caller never restores a guess.
    func displaySetting(_ setting: DisplaySetting) async throws -> String
    /// Changes `setting`, returning the value the device reports afterwards: read back, not echoed.
    func setDisplaySetting(_ setting: DisplaySetting, to value: String) async throws -> String
}

public extension DisplaySettingConfigurator {
    func displaySetting(_ setting: DisplaySetting) async throws -> String {
        throw AmooError.unsupportedCapability(
            key: "config.\(setting.rawValue)", reason: "This device cannot report its \(setting.rawValue) setting."
        )
    }

    func setDisplaySetting(_ setting: DisplaySetting, to _: String) async throws -> String {
        throw AmooError.unsupportedCapability(
            key: "config.\(setting.rawValue)", reason: "This device cannot change its \(setting.rawValue) setting."
        )
    }
}
