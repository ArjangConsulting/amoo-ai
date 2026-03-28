import Foundation

public struct Point: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Duration: Sendable, Equatable {
    public var milliseconds: Int

    public init(milliseconds: Int) {
        self.milliseconds = milliseconds
    }

    public static let defaultSwipe = Duration(milliseconds: 300)
    public static let defaultLongPress = Duration(milliseconds: 1000)
}

public enum Direction: String, Sendable, Equatable {
    case up
    case down
    case left
    case right
}

public struct Rect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum ImageFormat: String, Sendable, Equatable {
    case png
    case jpeg
}

public struct ScreenshotData: Sendable, Equatable {
    public var bytes: [UInt8]
    public var format: ImageFormat

    public init(bytes: [UInt8], format: ImageFormat = .png) {
        self.bytes = bytes
        self.format = format
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

public enum ElementType: String, Sendable, Equatable {
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
    public var id: String
    public var label: String
    public var value: String?
    public var type: ElementType?
    public var frame: Rect?
    public var isEnabled: Bool
    public var isVisible: Bool
    public var children: [ViewNode]

    public init(
        id: String,
        label: String = "",
        value: String? = nil,
        type: ElementType? = nil,
        frame: Rect? = nil,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        children: [ViewNode] = []
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.type = type
        self.frame = frame
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.children = children
    }
}

public struct ElementInfo: Sendable, Equatable {
    public var id: String
    public var label: String
    public var value: String?
    public var type: ElementType?
    public var frame: Rect?
    public var isEnabled: Bool
    public var isVisible: Bool

    public init(
        id: String,
        label: String,
        value: String? = nil,
        type: ElementType? = nil,
        frame: Rect? = nil,
        isEnabled: Bool = true,
        isVisible: Bool = true
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.type = type
        self.frame = frame
        self.isEnabled = isEnabled
        self.isVisible = isVisible
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

public enum Platform: String, Sendable, Equatable {
    case ios
    case android
}

public enum DeviceState: String, Sendable, Equatable {
    case booted
    case shutdown
    case unknown
}
