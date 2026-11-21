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

/// A native recording moved to the caller's output path.
public struct SavedVideo: Sendable, Equatable {
    public let path: String
    public let byteCount: Int
    /// The clip's own length from its header; shorter than the wait by the encoder's start-up time.
    public let recordedSeconds: Double?

    public init(path: String, byteCount: Int, recordedSeconds: Double?) {
        self.path = path
        self.byteCount = byteCount
        self.recordedSeconds = recordedSeconds
    }

    /// Below this a saved clip is one frame or close to it.
    static let stillScreenSeconds = 0.5

    /// The result `record_video` and `stop_recording` return.
    public func result(requestedSeconds: Double? = nil, stoppedBy: String? = nil) -> ToolResult {
        var fields: [String: Value] = [
            "saved_path": .string(path),
            "byte_count": .int(byteCount),
            "recorded_seconds": recordedSeconds.map { .double(($0 * 100).rounded() / 100) } ?? .null,
            "capture_method": .string("native_screen_recording")
        ]
        if let requestedSeconds {
            fields["requested_seconds"] = .double(requestedSeconds)
        }
        if let stoppedBy {
            fields["stopped_by"] = .string(stoppedBy)
        }
        let length = recordedSeconds.map { String(format: " (%.1fs)", $0) } ?? ""
        var content = "Native video saved to \(path)\(length). Frame rate depends on the device encoder."
        // An encoder that writes frames only on change (Android's) turns a still screen into one frame.
        if let recordedSeconds, recordedSeconds < Self.stillScreenSeconds {
            let note = "The clip is under half a second long: the screen did not change while recording, and"
                + " Android writes a frame only when it does. Drive the app during the recording to capture motion."
            fields["recording_note"] = .string(note)
            content += " " + note
        }
        return .success(content, structuredContent: .object(fields))
    }
}

/// Output validation and saving shared by `record_video`, `start_recording` and the CLI's detached recorder.
public enum NativeVideo {
    /// The `output` argument as a file URL that does not exist yet.
    public static func validatedOutput(_ raw: String?) throws -> URL {
        guard let raw, !raw.isEmpty else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "output is required for native video recording. Example: output=/tmp/clip.mp4"
            )
        }
        let output = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "Recording output already exists: \(output.path). Pass a new output path."
            )
        }
        return output
    }

    /// Moves the recorder's temporary file to `output`, readable only by this user.
    public static func save(recordingAt source: String, to output: URL) throws -> SavedVideo {
        let attributes = try FileManager.default.attributesOfItem(atPath: source)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw ToolExecutionError(
                code: "postcondition_failed",
                message: "The device returned an empty video recording."
            )
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try? FileManager.default.removeItem(atPath: source)
        return SavedVideo(path: output.path, byteCount: size, recordedSeconds: VideoDuration.seconds(at: output))
    }
}

extension DriverToolExecutor {
    func executeRecordVideo(driver: any PlatformDriver, arguments: [String: String]) async throws -> ToolResult {
        let recording = try VideoRecordingOptions(arguments: arguments)
        _ = try NativeVideo.validatedOutput(recording.output.path)
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
        let saved = try NativeVideo.save(recordingAt: path, to: recording.output)
        videoRecordingLogger.info(
            "Native video recording saved",
            context: "platform=\(platform) bytes=\(saved.byteCount)"
        )
        return saved.result(requestedSeconds: recording.duration)
    }
}
