/// Physical postures supported by the Android foldable emulator.
public enum DevicePosture: String, Sendable, CaseIterable {
    case closed
    case halfOpened = "half_opened"
    case opened
}

/// Display presets supported by Android's resizable emulator.
public enum DisplayPreset: String, Sendable, CaseIterable {
    case phone
    case unfolded
    case tablet
}

/// Display dimensions and density observed after changing an emulator preset.
public struct DeviceDisplayConfiguration: Sendable, Equatable {
    public let widthPixels: Int
    public let heightPixels: Int
    public let densityDPI: Int

    public init(widthPixels: Int, heightPixels: Int, densityDPI: Int) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.densityDPI = densityDPI
    }
}
