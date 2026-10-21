import Foundation

public struct StudioReplRequest: Codable, Sendable {
    public let command: String
    public let activeTest: StudioAuthoredTest
    public let selectedDeviceId: String?
    public let selectedProviderId: String?
    /// The selected device's platform (`ios` or `android`). Older Studio builds omit it, and the
    /// active test's platform is used instead.
    public let platform: String?
    /// Asks for a settled screenshot after any command that can change the screen.
    public let captureScreenshot: Bool?
    public init(
        command: String,
        activeTest: StudioAuthoredTest,
        selectedDeviceId: String?,
        selectedProviderId: String?,
        platform: String? = nil,
        captureScreenshot: Bool? = nil
    ) {
        self.command = command; self.activeTest = activeTest; self.selectedDeviceId = selectedDeviceId; self
            .selectedProviderId = selectedProviderId
        self.platform = platform
        self.captureScreenshot = captureScreenshot
    }
}

/// A console command's outcome. Fields after `output` are omitted by older Amoo builds.
public struct StudioReplResult: Codable, Equatable, Sendable {
    public let output: String
    /// True when a tool ran but reported failure; the output explains why.
    public let isError: Bool?
    /// The tool that ran, for tool commands.
    public let tool: String?
    /// The tool's structured result as JSON text, exactly as the tool produced it.
    public let structuredContent: String?
    /// Files the command wrote, such as screenshots.
    public let artifacts: [String]?
    /// The screen after the command, when the request asked for one or the command was a screenshot.
    public let screenshot: StudioScreenshot?
    /// Where a tap landed, in points, for overlaying on `screenshot`.
    public let gesturePoint: StudioPoint?
    /// While the console records, the session action this command recorded; a compiled plan names it
    /// `step-<actionIndex>`.
    public let actionIndex: Int?
    /// The recording session this command was recorded into.
    public let sessionId: String?

    public init(
        output: String,
        isError: Bool? = nil,
        tool: String? = nil,
        structuredContent: String? = nil,
        artifacts: [String]? = nil,
        screenshot: StudioScreenshot? = nil,
        gesturePoint: StudioPoint? = nil,
        actionIndex: Int? = nil,
        sessionId: String? = nil
    ) {
        self.actionIndex = actionIndex
        self.sessionId = sessionId
        self.output = output
        self.isError = isError
        self.tool = tool
        self.structuredContent = structuredContent
        self.artifacts = artifacts
        self.screenshot = screenshot
        self.gesturePoint = gesturePoint
    }
}

/// A saved screenshot and its geometry. Pixels divided by `scale` give points, the unit of gestures.
public struct StudioScreenshot: Codable, Equatable, Sendable {
    public let path: String
    public let widthPixels: Int?
    public let heightPixels: Int?
    public let widthPoints: Double?
    public let heightPoints: Double?
    public let scale: Double?

    public init(
        path: String,
        widthPixels: Int? = nil,
        heightPixels: Int? = nil,
        widthPoints: Double? = nil,
        heightPoints: Double? = nil,
        scale: Double? = nil
    ) {
        self.path = path
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.scale = scale
    }
}

public struct StudioPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Starts recording the console's commands on a device into a session, which launches the app fresh.
public struct StudioReplRecordingStartRequest: Codable, Sendable {
    public let deviceId: String
    public let platform: String
    public let appId: String
    public let buildPath: String?
    public let launchArguments: [String]?
    public let testName: String?

    public init(
        deviceId: String,
        platform: String,
        appId: String,
        buildPath: String? = nil,
        launchArguments: [String]? = nil,
        testName: String? = nil
    ) {
        self.deviceId = deviceId
        self.platform = platform
        self.appId = appId
        self.buildPath = buildPath
        self.launchArguments = launchArguments
        self.testName = testName
    }
}

public struct StudioReplRecordingStopRequest: Codable, Sendable {
    public let deviceId: String

    public init(deviceId: String) {
        self.deviceId = deviceId
    }
}

/// A console recording; after stopping, where its plan and flow were written.
public struct StudioReplRecording: Codable, Equatable, Sendable {
    public let sessionId: String
    public let deviceId: String
    public let actionCount: Int
    public let planPath: String?
    public let flowPath: String?
    public let message: String?

    public init(
        sessionId: String,
        deviceId: String,
        actionCount: Int,
        planPath: String? = nil,
        flowPath: String? = nil,
        message: String? = nil
    ) {
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.actionCount = actionCount
        self.planPath = planPath
        self.flowPath = flowPath
        self.message = message
    }
}
