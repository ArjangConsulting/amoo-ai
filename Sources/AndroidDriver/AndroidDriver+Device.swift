import AmooCore

/// Device-level controls over adb, kept apart from the companion-backed actions.
public extension AndroidDriver {
    func pressKey(_ key: KeyboardKey, modifiers: Set<KeyModifier>) async throws {
        let keyCode = key.androidKeyCode
        if modifiers.isEmpty {
            if let keyCode {
                _ = try await adb.run(adbArgs() + ["shell", "input", "keyevent", keyCode])
            } else {
                _ = try await adb.run(adbArgs() + ["shell", "input", "text", key.name])
            }
            return
        }
        guard let keyCode else {
            throw AmooError.commandFailed(
                command: "pressKey", output: "'\(key.name)' has no Android key code to combine with modifiers"
            )
        }
        // `keycombination` (Android 13+) holds every key down together, which a chord needs.
        _ = try await adb.run(
            adbArgs() + ["shell", "input", "keycombination"]
                + modifiers.sorted().map(\.androidKeyCode) + [keyCode]
        )
    }

    func setOrientation(_ orientation: DeviceOrientation) async throws -> DeviceOrientation {
        // Auto-rotate would hand control straight back to the (motionless) sensor.
        _ = try await adb.run(adbArgs() + ["shell", "settings", "put", "system", "accelerometer_rotation", "0"])
        _ = try await adb.run(adbArgs() + [
            "shell", "settings", "put", "system", "user_rotation", String(orientation.surfaceRotation)
        ])
        let readBack = try await adb.run(adbArgs() + ["shell", "settings", "get", "system", "user_rotation"])
        let value = readBack.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rotation = Int(value), let reported = DeviceOrientation(surfaceRotation: rotation) else {
            throw AmooError.commandFailed(command: "settings get system user_rotation", output: value)
        }
        return reported
    }

    func displaySetting(_ setting: DisplaySetting) async throws -> String {
        let command = setting.androidReadCommand
        let output = try await adb.run(adbArgs() + ["shell"] + command).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Self.displaySettingValue(setting, output: output) else {
            throw AmooError.commandFailed(command: command.joined(separator: " "), output: output)
        }
        return value
    }

    func setDisplaySetting(_ setting: DisplaySetting, to value: String) async throws -> String {
        guard let canonical = setting.canonicalValue(value, for: .android) else {
            throw AmooError.commandFailed(
                command: "set \(setting.rawValue)", output: "'\(value)' is not a value Android accepts."
            )
        }
        _ = try await adb.run(adbArgs() + ["shell"] + setting.androidWriteCommand(canonical))
        return try await displaySetting(setting)
    }

    /// Parses what Android prints for a setting. A key that was never written reads `null`, which
    /// is the platform default; `cmd uimode night` answers `Night mode: yes|no|auto`.
    static func displaySettingValue(_ setting: DisplaySetting, output: String) -> String? {
        switch setting {
        case .appearance:
            guard let mode = output.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else {
                return nil
            }
            return ["yes": "dark", "no": "light", "auto": "auto"][mode.lowercased()]
        case .textSize:
            if output == "null" || output.isEmpty {
                return "1.0"
            }
            return Double(output).map { String($0) }
        case .increaseContrast:
            return ["1": "enabled", "0": "disabled", "null": "disabled", "": "disabled"][output]
        }
    }

    /// Element frames are screen pixels. The active display density accounts for resizable presets;
    /// `wm density` is a fallback when active display information is unavailable. dp = px * 160 / dpi.
    func elementGeometry() async throws -> ElementGeometry? {
        if let display = try? await adb.run(adbArgs() + ["shell", "dumpsys", "display"], timeoutSeconds: 2),
           let configuration = Self.activeDisplayConfiguration(display.stdout) {
            return ElementGeometry(unit: "dp", framesPerUnit: Double(configuration.densityDPI) / 160)
        }
        guard let result = try? await adb.run(adbArgs() + ["shell", "wm", "density"], timeoutSeconds: 5),
              result.exitCode == 0, let dpi = Self.effectiveDensity(result.stdout) else { return nil }
        return ElementGeometry(unit: "dp", framesPerUnit: dpi / 160)
    }

    /// Parses `wm density`: `Physical density: 420` plus an optional `Override density: 480`.
    static func effectiveDensity(_ output: String) -> Double? {
        var physical: Double?
        var override: Double?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let value = Double(parts[1].trimmingCharacters(in: .whitespaces)), value.isFinite, value > 0
            else { continue }
            if parts[0].contains("Override") {
                override = value
            } else if parts[0].contains("Physical") {
                physical = value
            }
        }
        return override ?? physical
    }
}

extension DeviceOrientation {
    /// `Surface.ROTATION_*`: quarter turns counter-clockwise from the natural (portrait) position,
    /// so a device turned counter-clockwise — `landscapeLeft` — is `ROTATION_90`.
    var surfaceRotation: Int {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        }
    }

    init?(surfaceRotation: Int) {
        guard let match = Self.allCases.first(where: { $0.surfaceRotation == surfaceRotation }) else { return nil }
        self = match
    }
}

extension KeyboardKey {
    /// `KEYCODE_*` name for `input keyevent`; `nil` for characters with no single key code.
    var androidKeyCode: String? {
        switch self {
        case .leftArrow: "KEYCODE_DPAD_LEFT"
        case .rightArrow: "KEYCODE_DPAD_RIGHT"
        case .upArrow: "KEYCODE_DPAD_UP"
        case .downArrow: "KEYCODE_DPAD_DOWN"
        case .returnKey: "KEYCODE_ENTER"
        case .escape: "KEYCODE_ESCAPE"
        case .tab: "KEYCODE_TAB"
        case .space: "KEYCODE_SPACE"
        case .delete: "KEYCODE_DEL"
        case .home: "KEYCODE_MOVE_HOME"
        case .end: "KEYCODE_MOVE_END"
        case .pageUp: "KEYCODE_PAGE_UP"
        case .pageDown: "KEYCODE_PAGE_DOWN"
        case let .character(character):
            if let letter = character.uppercased().first, letter.isASCII, letter.isLetter || letter.isNumber {
                "KEYCODE_\(letter)"
            } else {
                nil
            }
        }
    }
}

extension KeyModifier {
    var androidKeyCode: String {
        switch self {
        case .command: "KEYCODE_META_LEFT"
        case .shift: "KEYCODE_SHIFT_LEFT"
        case .option: "KEYCODE_ALT_LEFT"
        case .control: "KEYCODE_CTRL_LEFT"
        }
    }
}

private extension DisplaySetting {
    var androidReadCommand: [String] {
        switch self {
        case .appearance: ["cmd", "uimode", "night"]
        case .textSize: ["settings", "get", "system", "font_scale"]
        case .increaseContrast: ["settings", "get", "secure", "high_text_contrast_enabled"]
        }
    }

    func androidWriteCommand(_ value: String) -> [String] {
        switch self {
        case .appearance:
            ["cmd", "uimode", "night", ["dark": "yes", "light": "no"][value] ?? "auto"]
        case .textSize:
            ["settings", "put", "system", "font_scale", value]
        case .increaseContrast:
            ["settings", "put", "secure", "high_text_contrast_enabled", value == "enabled" ? "1" : "0"]
        }
    }
}
