import AmooCore
import AmooLogging
import Foundation

private let videoRecordingLogger = AmooLogger.forType(VideoRecordingOptions.self)

/// Validated `record_video` arguments: a bounded duration and an output path that does not exist yet.
struct VideoRecordingOptions: Equatable {
    static let durationRange: ClosedRange<TimeInterval> = 1 ... 60
    static let defaultDuration: TimeInterval = 5

    let duration: TimeInterval
    let output: URL

    init(arguments: [String: String]) throws {
        guard let duration = TimeInterval(arguments["duration_seconds"] ?? "\(Self.defaultDuration)"),
              duration.isFinite, Self.durationRange.contains(duration)
        else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "duration_seconds must be a finite number from 1 to 60. Example: duration_seconds=5"
            )
        }
        guard let output = arguments["output"], !output.isEmpty else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "output is required for native video recording. Example: output=/tmp/clip.mp4"
            )
        }
        self.duration = duration
        self.output = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    }
}

/// Starts a native recording, waits `duration`, and stops the same recording, also when the wait is
/// cancelled, so the host recorder (`simctl io recordVideo`, `screenrecord`) never outlives the call.
func captureDeviceVideo(
    duration: TimeInterval,
    start: @Sendable () async throws -> RecordingSession,
    stop: @escaping @Sendable (String) async throws -> String,
    wait: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
) async throws -> String {
    let recording = try await start()
    do {
        try await wait(duration)
    } catch {
        let cleanup = Task { try await stop(recording.id) }
        _ = try? await cleanup.value
        throw error
    }
    return try await stop(recording.id)
}

extension DriverToolExecutor {
    func executeRecordVideo(driver: any PlatformDriver, arguments: [String: String]) async throws -> ToolResult {
        let recording = try VideoRecordingOptions(arguments: arguments)
        guard !FileManager.default.fileExists(atPath: recording.output.path) else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "Recording output already exists: \(recording.output.path). Pass a new output path."
            )
        }
        let platform = defaultPlatform?.rawValue ?? "unknown"
        videoRecordingLogger.info(
            "Starting native video recording",
            context: "platform=\(platform) duration=\(recording.duration)"
        )
        let path: String
        do {
            path = try await captureDeviceVideo(
                duration: recording.duration,
                start: { try await driver.startRecording() },
                stop: { try await driver.stopRecording(sessionID: $0) }
            )
        } catch {
            videoRecordingLogger.error(
                "Native video recording failed",
                error: error,
                context: "feature=record_video action=capture platform=\(platform)"
            )
            throw error
        }
        let source = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw ToolExecutionError(
                code: "postcondition_failed",
                message: "The device returned an empty video recording."
            )
        }
        try FileManager.default.createDirectory(
            at: recording.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: recording.output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recording.output.path)
        try? FileManager.default.removeItem(at: source)
        videoRecordingLogger.info("Native video recording saved", context: "platform=\(platform) bytes=\(size)")
        return .success(
            "Native video saved to \(recording.output.path). Frame rate depends on the device encoder.",
            structuredContent: .object([
                "saved_path": .string(recording.output.path),
                "duration_seconds": .double(recording.duration),
                "byte_count": .int(size),
                "capture_method": .string("native_screen_recording")
            ])
        )
    }
}
