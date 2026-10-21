import Foundation

/// A console recording: commands on its device are recorded into this session.
struct ConsoleRecording: Sendable {
    let sessionId: String
    var actionCount = 0
}

/// Console recording. While a device records, console tools run through its session, so each command
/// becomes a recorded action and `end_session` turns them into a plan Studio can generate a test from.
/// Screenshots and completion use unrecorded paths, so they never become steps.
public extension LiveStudioAutomationService {
    internal static let recordingOwner = "the console"
    private static let recordedElementLifetime: Duration = .seconds(3)

    func canRecord() -> Bool {
        sessionDriver != nil
    }

    /// Starts a session for the device, which launches the app fresh. Starting again while recording
    /// returns the current recording.
    func startRecording(_ request: StudioReplRecordingStartRequest) async throws -> StudioReplRecording {
        guard let sessionDriver else {
            throw StudioAutomationError.invalidTest("Console recording is unavailable in this Amoo build.")
        }
        if let current = recordings[request.deviceId] {
            return .init(sessionId: current.sessionId, deviceId: request.deviceId, actionCount: current.actionCount)
        }
        guard startingRecordings.insert(request.deviceId).inserted else {
            throw StudioAutomationError.invalidTest("A recording is already starting on this device.")
        }
        defer { startingRecordings.remove(request.deviceId) }
        try await deviceSessions.claim(request.deviceId, for: Self.recordingOwner)
        let spec = StudioSessionSpec(
            deviceId: request.deviceId,
            platform: request.platform.lowercased(),
            appId: request.appId,
            buildPath: request.buildPath,
            launchArguments: request.launchArguments,
            testName: request.testName
        )
        logger.info("Console recording starting", context: "deviceId=\(request.deviceId)")
        do {
            let sessionId = try await deviceLocks.withDevice(request.deviceId) {
                try await sessionDriver.startSession(spec)
            }
            recordings[request.deviceId] = ConsoleRecording(sessionId: sessionId)
            logger.info("Console recording started", context: "deviceId=\(request.deviceId) sessionId=\(sessionId)")
            return .init(sessionId: sessionId, deviceId: request.deviceId, actionCount: 0)
        } catch {
            await deviceSessions.release(request.deviceId, from: Self.recordingOwner)
            logger.error("Console recording failed to start", error: error, context: "deviceId=\(request.deviceId)")
            throw error
        }
    }

    /// Ends the device's session, writing its plan, and releases the device.
    func stopRecording(_ request: StudioReplRecordingStopRequest) async throws -> StudioReplRecording {
        guard let sessionDriver, let recording = recordings.removeValue(forKey: request.deviceId) else {
            throw StudioAutomationError.invalidTest("The console is not recording on this device.")
        }
        recordedElements[recording.sessionId] = nil
        let end = await (try? deviceLocks.withDevice(request.deviceId) {
            await sessionDriver.endSession(sessionId: recording.sessionId)
        }) ?? StudioAgentSessionEnd(planPath: nil, flowPath: nil, message: "The session did not end cleanly.")
        await deviceSessions.release(request.deviceId, from: Self.recordingOwner)
        logger.info(
            "Console recording stopped",
            context: "deviceId=\(request.deviceId) sessionId=\(recording.sessionId) actions=\(recording.actionCount)"
        )
        return .init(
            sessionId: recording.sessionId,
            deviceId: request.deviceId,
            actionCount: recording.actionCount,
            planPath: end.planPath,
            flowPath: end.flowPath,
            message: end.message
        )
    }

    func stopAllRecordings() async {
        for deviceId in Array(recordings.keys) {
            _ = try? await stopRecording(.init(deviceId: deviceId))
        }
    }

    /// Runs a console tool through the device's recording session. The caller holds the device lock.
    internal func recordedToolResult(
        tool name: String,
        arguments: [String: String],
        readOnly: Bool,
        deviceId: String,
        request: StudioReplRequest
    ) async -> StudioReplResult? {
        guard let sessionDriver, let recording = recordings[deviceId] else { return nil }
        var routed = arguments
        routed["session_id"] = recording.sessionId
        logger.info("Recorded console tool started", context: "tool=\(name) sessionId=\(recording.sessionId)")
        let outcome = await sessionDriver.execute(sessionId: recording.sessionId, tool: name, arguments: routed)
        let actionIndex = recording.actionCount
        recordings[deviceId]?.actionCount += 1
        if !readOnly {
            recordedElements[recording.sessionId] = nil
        }
        let wantsScreen = name == "take_screenshot" || (!readOnly && request.captureScreenshot == true)
        let screenshot = wantsScreen ? await sessionDriver.observeScreen(sessionId: recording.sessionId) : nil
        logger.info("Recorded console tool finished", context: "tool=\(name) isError=\(outcome.isError)")
        return .init(
            output: outcome.output,
            isError: outcome.isError,
            tool: name,
            structuredContent: outcome.structuredContent,
            screenshot: screenshot,
            gesturePoint: Self.gesturePoint(
                tool: name,
                arguments: arguments,
                structuredContent: outcome.structuredContent
            ),
            actionIndex: actionIndex,
            sessionId: recording.sessionId
        )
    }

    /// Elements for completion: from the recording session when the device records, else the console's
    /// own connection.
    internal func suggestedElements(deviceId: String, platform: String) async throws -> [StudioElementSuggestion] {
        guard let sessionDriver, let recording = recordings[deviceId] else {
            return try await elementSuggester?.elements(deviceId: deviceId, platform: platform) ?? []
        }
        if let cached = recordedElements[recording.sessionId],
           ContinuousClock.now - cached.capturedAt < Self.recordedElementLifetime {
            return cached.elements
        }
        let elements = await sessionDriver.observeElements(sessionId: recording.sessionId)
        recordedElements[recording.sessionId] = (.now, elements)
        return elements
    }
}
