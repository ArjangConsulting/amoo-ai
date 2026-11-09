import Foundation

public struct Duration: Sendable, Equatable {
    public var milliseconds: Int

    public init(milliseconds: Int) {
        self.milliseconds = milliseconds
    }

    public static let defaultSwipe = Self(milliseconds: 300)
    public static let defaultLongPress = Self(milliseconds: 1000)
}

public enum Direction: String, Sendable, Equatable {
    case up
    case down
    case left
    case right
}

public enum ImageFormat: String, Sendable, Equatable {
    case png
    case jpeg

    /// Parses a user-supplied format string, accepting the common "jpg" alias
    /// case-insensitively. Unrecognized or missing values fall back to `.png`.
    public init(parsing string: String?) {
        switch string?.lowercased() {
        case "jpeg", "jpg": self = .jpeg
        default: self = .png
        }
    }

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        }
    }
}

/// Whether the physical/simulated screen is on, off, or locked at the point a screenshot was
/// captured or an app was launched — without this, an all-black PNG or a launch that never comes
/// to front looks indistinguishable from an app bug.
public enum ScreenPowerState: String, Sendable, Equatable {
    case on
    case locked
    case off
}

public struct ScreenshotData: Sendable, Equatable {
    public var bytes: [UInt8]
    public var format: ImageFormat
    /// Fraction of native pixels per side applied where the image was captured; `nil` when the
    /// image is at native resolution.
    public var appliedScale: Double?
    /// Native pixels per point (iOS) or per density-independent pixel (Android), when known.
    public var density: Double?
    /// Screen geometry reported with the capture, so callers need no separate geometry call.
    public var geometry: ScreenSize?

    public init(
        bytes: [UInt8],
        format: ImageFormat = .png,
        appliedScale: Double? = nil,
        density: Double? = nil,
        geometry: ScreenSize? = nil
    ) {
        self.bytes = bytes
        self.format = format
        self.appliedScale = appliedScale
        self.density = density
        self.geometry = geometry
    }
}

/// How a screenshot should be sized and encoded. Drivers that cannot scale at the source return
/// native pixels (`ScreenshotData.appliedScale == nil`) and the caller scales instead.
public struct ScreenshotRequestOptions: Sendable, Equatable {
    public var format: ImageFormat
    /// Fraction of native pixels per side in (0, 1]; `nil` for native unless `pointResolution`.
    public var scale: Double?
    /// One image pixel per point / density-independent pixel (scale = 1 / density); overrides `scale`.
    public var pointResolution: Bool
    /// JPEG quality in (0, 1]; `nil` for the driver default.
    public var quality: Double?

    public init(
        format: ImageFormat = .png,
        scale: Double? = nil,
        pointResolution: Bool = false,
        quality: Double? = nil
    ) {
        self.format = format
        self.scale = scale
        self.pointResolution = pointResolution
        self.quality = quality
    }
}

public struct RecordingSession: Sendable, Equatable {
    public var id: String
    public var deviceID: String

    public init(id: String, deviceID: String) {
        self.id = id
        self.deviceID = deviceID
    }
}

public enum ElementType: String, Sendable, Equatable, CaseIterable {
    case button
    case textField
    case staticText
    case image
    case cell
    case scrollView
    case table
    case collectionView
    case navigationBar
    case tabBar
    case switchControl = "switch"
    case slider
    case picker
    case alert
    case sheet
    case webView
    case other
}

public struct ViewNode: Sendable, Equatable {
    public var isSelected: Bool?
    public var semantics: ElementSemantics?
    public var id: String
    public var label: String
    public var value: String?
    public var type: ElementType?
    public var frame: Rect?
    /// Preferred screen-space coordinate for interacting with the visible portion of this node.
    public var hitPoint: Point?
    public var isEnabled: Bool
    public var isSecureTextEntry: Bool
    public var isVisible: Bool
    public var children: [Self]
    /// Placeholder (iOS) or hint (Android) text; `nil` when the capture source does not report it.
    public var placeholder: String?
    /// On a root read from a companion: its content digest, comparable with the digest of another
    /// root read from the same companion.
    public var contentDigest: String?

    public init(
        id: String,
        label: String = "",
        value: String? = nil,
        type: ElementType? = nil,
        frame: Rect? = nil,
        hitPoint: Point? = nil,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        children: [Self] = [],
        isSecureTextEntry: Bool = false,
        placeholder: String? = nil,
        semantics: ElementSemantics? = nil,
        isSelected: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.type = type
        self.frame = frame
        self.hitPoint = hitPoint
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.isSecureTextEntry = isSecureTextEntry
        self.children = children
        self.placeholder = placeholder
        self.semantics = semantics
        self.isSelected = isSelected
    }
}

public struct ElementInfo: Sendable, Equatable {
    public var semantics: ElementSemantics?
    public var isSelected: Bool?
    public var id: String
    public var label: String
    public var value: String?
    public var type: ElementType?
    public var frame: Rect?
    /// Preferred screen-space coordinate for interaction; use before falling back to frame center.
    public var hitPoint: Point?
    public var isEnabled: Bool
    public var isSecureTextEntry: Bool
    public var isVisible: Bool
    /// Placeholder (iOS) or hint (Android) a screen reader announces for an empty input;
    /// `nil` when the capture source does not report it.
    public var placeholder: String?

    public init(
        id: String,
        label: String,
        value: String? = nil,
        type: ElementType? = nil,
        frame: Rect? = nil,
        hitPoint: Point? = nil,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        isSecureTextEntry: Bool = false,
        isSelected: Bool? = nil,
        placeholder: String? = nil,
        semantics: ElementSemantics? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.type = type
        self.frame = frame
        self.hitPoint = hitPoint
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.isSecureTextEntry = isSecureTextEntry
        self.isSelected = isSelected
        self.placeholder = placeholder
        self.semantics = semantics
    }
}

public struct ScreenContext: Sendable, Equatable {
    public var summary: String
    public var interactableCount: Int
    public var screenTitle: String?

    public init(summary: String, interactableCount: Int = 0, screenTitle: String? = nil) {
        self.summary = summary
        self.interactableCount = interactableCount
        self.screenTitle = screenTitle
    }
}

public struct PermissionChange: Sendable, Equatable {
    public var appID: String
    public var permission: String
    public var granted: Bool

    public init(appID: String, permission: String, granted: Bool) {
        self.appID = appID
        self.permission = permission
        self.granted = granted
    }
}

public struct AppInfo: Sendable, Equatable {
    public var appID: String
    public var name: String?
    public var version: String?

    public init(appID: String, name: String? = nil, version: String? = nil) {
        self.appID = appID
        self.name = name
        self.version = version
    }
}

public enum AppState: String, Sendable, Equatable {
    case running
    case suspended
    case notRunning
    case notInstalled
    case unknown
}

public enum Appearance: String, Sendable, Equatable {
    case light
    case dark
}

/// Physical device orientation, named for the device the way `UIDeviceOrientation` is:
/// `landscapeLeft` is the device turned counter-clockwise, top edge on the left.
public enum DeviceOrientation: String, Sendable, Equatable, CaseIterable {
    case portrait
    case portraitUpsideDown = "portrait_upside_down"
    case landscapeLeft = "landscape_left"
    case landscapeRight = "landscape_right"
}

public struct DeviceInfo: Sendable, Equatable {
    public var id: String
    public var name: String
    public var platform: Platform
    public var osVersion: String
    public var state: DeviceState

    public init(id: String, name: String, platform: Platform, osVersion: String, state: DeviceState) {
        self.id = id
        self.name = name
        self.platform = platform
        self.osVersion = osVersion
        self.state = state
    }
}

public enum Platform: String, Sendable, Equatable, Hashable, Codable {
    case ios
    case android
    /// This Mac's desktop, driven by the macOS companion. Experimental.
    case macos

    /// Accepts the loose spellings that reach us from AI-authored plans, recorded sessions and CLI
    /// input (`iOS`, `Android`, `android-emulator`, `macOS`, …), and rejects everything else.
    ///
    /// This is the single place that turns an untyped platform string into a `Platform`. Every
    /// entry point — `Decodable`, string-based initializers, session compilation — routes through
    /// it, so leniency stays confined to one function and none of them can quietly disagree about
    /// what an unrecognized value means.
    public init?(lenient raw: String) {
        let value = raw.lowercased()
        if value.contains("android") {
            self = .android
        } else if value.contains("macos") || value == "mac" || value == "osx" {
            self = .macos
        } else if value.contains("ios") {
            self = .ios
        } else {
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = Self(lenient: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported platform '\(raw)'; expected iOS, Android or macOS."
            )
        }
        self = parsed
    }
}

public enum UIToolkit: String, Codable, Sendable, Hashable, CaseIterable {
    /// UIKit on iOS and the classic View hierarchy on Android.
    case view
    case compose
}

public enum DeviceState: String, Sendable, Equatable {
    case booted
    case shutdown
    case unknown
}

/// Gesture space (points) and screenshot space (pixels), plus the factor between them.
public struct ScreenSize: Sendable, Equatable {
    public let widthPoints: Double
    public let heightPoints: Double
    public let widthPixels: Double
    public let heightPixels: Double
    public let scale: Double

    public init(
        widthPoints: Double,
        heightPoints: Double,
        widthPixels: Double,
        heightPixels: Double,
        scale: Double
    ) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.scale = scale
    }
}

public extension ScreenCapture {
    func takeScreenshot(_ options: ScreenshotRequestOptions) async throws -> ScreenshotData {
        try await takeScreenshot(format: options.format)
    }
}
