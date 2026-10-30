import Foundation

/// What a failed `adb install` of a companion APK means and the supported way past it.
///
/// `adb` reports the reason as an `INSTALL_FAILED_*` code on stderr. The recovery text names only
/// amoo commands, never raw `adb`, so a delegated agent can follow it without desyncing the channel.
struct AndroidInstallDiagnosis: Equatable {
    /// The `INSTALL_*` code from adb, or `nil` when adb printed none.
    var code: String?
    var cause: String
    var recovery: String
    /// True when removing the amoo-owned companion packages and installing again can succeed.
    var reinstallFixes: Bool

    /// Matches `INSTALL_FAILED_OLDER_SDK`, `INSTALL_PARSE_FAILED_NO_CERTIFICATES` and the like.
    private static let codePattern = "INSTALL_(?:PARSE_)?FAILED_[A-Z0-9_]+"

    private static let anotherAVD = "another AVD (`amoo env up --platform android --avd <name>`; API 35 images work)"

    static func diagnose(output: String, apiLevel: Int? = nil) -> Self {
        let code = output.range(of: codePattern, options: .regularExpression).map { String(output[$0]) }
        let level = apiLevel.map { "API \($0)" } ?? "this Android version"
        switch code {
        case "INSTALL_FAILED_OLDER_SDK":
            return Self(
                code: code,
                cause: "\(level) is older than the companion's minimum of "
                    + "API \(AndroidCompanionConfig.minimumAPILevel).",
                recovery: "Use \(anotherAVD) on API \(AndroidCompanionConfig.minimumAPILevel) or newer.",
                reinstallFixes: false
            )
        case "INSTALL_FAILED_DEPRECATED_SDK_VERSION", "INSTALL_FAILED_NEWER_SDK":
            return Self(
                code: code,
                cause: "\(level) refuses the companion's target SDK; the prebuilt companion predates it.",
                recovery: "Upgrade amoo (`brew upgrade amoo`) for a companion built for this release. "
                    + "Until then use \(anotherAVD).",
                reinstallFixes: false
            )
        case "INSTALL_FAILED_NO_MATCHING_ABIS":
            return Self(
                code: code,
                cause: "The device's CPU architecture is not one the companion ships native code for.",
                recovery: "Use \(anotherAVD) whose ABI matches this host (arm64-v8a on Apple silicon).",
                reinstallFixes: false
            )
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE":
            return Self(
                code: code,
                cause: "The device has no room left on /data.",
                recovery: "Cold-boot this AVD with its data wiped, or use \(anotherAVD).",
                reinstallFixes: false
            )
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE", "INSTALL_FAILED_VERSION_DOWNGRADE",
             "INSTALL_FAILED_INVALID_APK", "INSTALL_FAILED_DUPLICATE_PERMISSION":
            return Self(
                code: code,
                cause: "A companion with a different signature or newer version is already installed.",
                recovery: "amoo removes its own companion packages and retries once; if this persists run "
                    + "`amoo companion install --platform android --device <serial> --force`, or use \(anotherAVD).",
                reinstallFixes: true
            )
        case "INSTALL_FAILED_USER_RESTRICTED", "INSTALL_FAILED_VERIFICATION_FAILURE":
            return Self(
                code: code,
                cause: "The device blocks USB installs (a user restriction or Play Protect).",
                recovery: "Allow installs over USB in the device's developer options, or use an emulator.",
                reinstallFixes: false
            )
        default:
            return fallback(code: code, output: output)
        }
    }

    private static func fallback(code: String?, output: String) -> Self {
        let lowered = output.lowercased()
        if lowered.contains("device offline") || lowered.contains("not found")
            || lowered.contains("unauthorized") || lowered.contains("no devices") {
            return Self(
                code: code,
                cause: "The device went offline or is not authorized.",
                recovery: "Wait for boot with `session_startup_status`, or use \(anotherAVD).",
                reinstallFixes: false
            )
        }
        return Self(
            code: code,
            cause: code.map { "adb reported \($0), which amoo has no specific guidance for." }
                ?? "adb exited non-zero without printing a reason.",
            recovery: "Run `amoo doctor --cli-only --json` and read the device and runtime entries, then "
                + "try \(anotherAVD). Report the output above if it recurs on an API 35 image.",
            reinstallFixes: false
        )
    }

    /// The failure text shown to the caller: what failed, adb's own words, likely cause, next step.
    func message(label: String, serial: String?, apiLevel: Int?, output: String) -> String {
        let device = [serial, apiLevel.map { "API \($0)" }].compactMap(\.self).joined(separator: ", ")
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Failed to install Android \(label) APK\(device.isEmpty ? "" : " on \(device)"):
        \(trimmed.isEmpty ? "(adb printed nothing)" : trimmed)
        Likely cause: \(cause)
        Recovery: \(recovery)
        """
    }
}
