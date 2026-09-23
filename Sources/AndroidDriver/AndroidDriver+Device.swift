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
