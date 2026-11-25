import AmooCore
import AmooLogging
import Foundation

/// Turns password AutoFill off on an iOS simulator, through the restriction iOS keeps in the
/// simulator's user settings (`restrictedBool.allowPasswordAutoFill`).
///
/// With AutoFill on, a simulator where a password was once typed by a UI test offers "Save
/// Password?" after every later sign-in. Once that sheet has settled, the accessibility tree shows
/// only the application, so nothing can find or answer it, and a sign-in flow passes or fails by the
/// simulator's history. iOS reads the file only while booting, so it is written while the simulator
/// is shut down. The key is iOS's own, not a documented interface, and may move in a later release;
/// a file without it is left unchanged and reported.
enum SimulatorPasswordAutoFill {
    /// What `env up --disable-password-autofill` did, reported as `password_autofill`.
    enum Outcome: String, Codable, Equatable {
        /// amoo turned it off before booting the simulator.
        case disabled
        case alreadyOff = "already_off"
        /// The simulator was already running, and amoo does not shut down a running simulator.
        case leftOn = "left_on"
        /// The settings file has no such key on this iOS version.
        case unsupported

        /// The `env up` line for it.
        func summary(udid: String) -> String {
            switch self {
            case .disabled: "Password AutoFill: turned off (it stays off on this simulator)."
            case .alreadyOff: "Password AutoFill: already off."
            case .leftOn:
                "Password AutoFill is still on: the simulator was already running, and env up does not shut down"
                    + " a running simulator. Run `xcrun simctl shutdown \(udid)`, then env up again with"
                    + " --disable-password-autofill."
            case .unsupported:
                "Password AutoFill was left on: this iOS version's settings have no allowPasswordAutoFill restriction."
            }
        }
    }

    private static let logger = AmooLogger.forType(Self.self)

    /// The user settings file of the simulator in the default device set.
    static func settingsURL(udid: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Developer/CoreSimulator/Devices/\(udid)/data/Containers/Shared/SystemGroup")
            .appending(path: "systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles")
            .appending(path: "UserSettings.plist")
    }

    /// Turns AutoFill off before `env up` boots the simulator. A running simulator is left as it is:
    /// shutting it down would end whatever else uses it. One that has never booted has no settings
    /// yet, so `bootOnce` boots it and shuts it down again for iOS to write them.
    static func turnOffBeforeBoot(
        udid: String,
        running: Bool,
        settings url: URL? = nil,
        bootOnce: () async throws -> Void
    ) async throws -> Outcome {
        let url = url ?? settingsURL(udid: udid)
        if isOff(at: url) == true {
            return .alreadyOff
        }
        if running {
            return .leftOn
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            logger.info("Booting a never-booted simulator once to create its settings")
            await StartupProgress
                .report("Booting the simulator once so iOS writes its settings, then turning AutoFill off")
            try await bootOnce()
        }
        return try turnOff(at: url) ? .disabled : .unsupported
    }

    /// Whether AutoFill is off in `url`: `nil` when the file or the key is missing (a simulator that
    /// has never booted has no file yet).
    static func isOff(at url: URL) -> Bool? {
        guard let settings = try? read(url).settings,
              let value = setting(in: settings) else { return nil }
        return value == false
    }

    /// Writes AutoFill off into `url`, keeping the file's format. Returns `false`, changing nothing,
    /// when the file has no `allowPasswordAutoFill` restriction to change.
    static func turnOff(at url: URL) throws -> Bool {
        var (settings, format) = try read(url)
        guard var restricted = settings["restrictedBool"] as? [String: Any],
              var entry = restricted["allowPasswordAutoFill"] as? [String: Any] else {
            logger.info("Password AutoFill restriction not found; settings left unchanged")
            return false
        }
        entry["value"] = false
        restricted["allowPasswordAutoFill"] = entry
        settings["restrictedBool"] = restricted
        let data = try PropertyListSerialization.data(fromPropertyList: settings, format: format, options: 0)
        try data.write(to: url, options: .atomic)
        logger.info("Password AutoFill turned off in simulator settings")
        return true
    }

    private static func read(_ url: URL) throws -> (
        settings: [String: Any],
        format: PropertyListSerialization
            .PropertyListFormat
    ) {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard let settings = plist as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return (settings, format)
    }

    private static func setting(in settings: [String: Any]) -> Bool? {
        let restricted = settings["restrictedBool"] as? [String: Any]
        let entry = restricted?["allowPasswordAutoFill"] as? [String: Any]
        return entry?["value"] as? Bool
    }
}
