import AmooCore
import AmooLogging
import Foundation

private let recordingLogger = AmooLogger.forType(ActiveToolRecording.self)

/// A `start_recording` this executor holds until `stop_recording`, its `max_seconds`, or the end of a flow.
struct ActiveToolRecording: Sendable {
    let driver: any PlatformDriver
    let session: RecordingSession
    let output: URL
    var autoStop: Task<Void, Never>?
    /// Started once, by whichever comes first: `stop_recording` or the `max_seconds` timer.
    var stop: Task<Result<SavedVideo, ToolExecutionError>, Never>?
    var stoppedBy: String?
}

/// `max_seconds` bounds for `start_recording`, shared with the CLI's detached recorder.
public enum RecordingLimits {
    public static let maxSecondsRange: ClosedRange<Double> = 1 ... 600
    public static let defaultMaxSeconds: Double = 300
    /// `screenrecord` ends every recording at three minutes.
    public static let androidMaxSeconds: Double = 180

    public static func maxSeconds(_ raw: String?, platform: Platform?) throws -> Double {
        let ceiling = platform == .android ? androidMaxSeconds : maxSecondsRange.upperBound
        guard let raw else { return min(defaultMaxSeconds, ceiling) }
        guard let value = Double(raw), value.isFinite, (maxSecondsRange.lowerBound ... ceiling).contains(value) else {
            let reason = platform == .android ? " Android's screenrecord stops at 180 seconds." : ""
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "max_seconds must be a number from 1 to \(Int(ceiling)).\(reason) Example: max_seconds=60"
            )
        }
        return value
    }
}

extension DriverToolExecutor {
    private func recordingKey(_ arguments: [String: String]) -> String {
        arguments["session_id"] ?? "default"
    }

    func executeStartRecording(driver: any PlatformDriver, arguments: [String: String]) async throws -> ToolResult {
        let key = recordingKey(arguments)
        if let active = activeRecordings[key], active.stop == nil {
            throw ToolExecutionError(
                code: "recording_active",
                message: "A recording to \(active.output.path) is already running. Call stop_recording first."
            )
        }
        let output = try NativeVideo.validatedOutput(arguments["output"])
        let platform: Platform? = if let defaultPlatform {
            defaultPlatform
        } else {
            try? await driver.deviceInfo().platform
        }
        let maxSeconds = try RecordingLimits.maxSeconds(arguments["max_seconds"], platform: platform)
        recordingLogger.info("Starting recording", context: "key=\(key) max_seconds=\(maxSeconds)")
        let session: RecordingSession
        do {
            session = try await driver.startRecording()
        } catch {
            recordingLogger.error(
                "Recording failed to start",
                error: error,
                context: "feature=start_recording key=\(key)"
            )
            throw error
        }
        let autoStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxSeconds))
            guard !Task.isCancelled else { return }
            await self?.expireRecording(key: key, sessionID: session.id)
        }
        activeRecordings[key] = ActiveToolRecording(
            driver: driver,
            session: session,
            output: output,
            autoStop: autoStop
        )
        recordingLogger.info("Recording started", context: "key=\(key)")
        return .success(
            "Recording to \(output.path). Call stop_recording to save it; it stops by itself after"
                + " \(Int(maxSeconds)) seconds.",
            structuredContent: .object([
                "output": .string(output.path), "max_seconds": .double(maxSeconds), "recording": .bool(true)
            ])
        )
    }

    func executeStopRecording(arguments: [String: String]) async throws -> ToolResult {
        let key = recordingKey(arguments)
        guard let stop = beginStoppingRecording(key: key, stoppedBy: "stop_recording") else {
            throw ToolExecutionError(
                code: "no_active_recording",
                message: "No recording is running. Start one with start_recording output=<path.mp4>."
            )
        }
        let stoppedBy = activeRecordings[key]?.stoppedBy
        let outcome = await stop.value
        activeRecordings[key] = nil
        switch outcome {
        case let .success(saved):
            recordingLogger.info("Recording saved", context: "key=\(key) bytes=\(saved.byteCount)")
            return saved.result(stoppedBy: stoppedBy)
        case let .failure(error):
            recordingLogger.error(
                "Recording failed to stop",
                error: error,
                context: "feature=stop_recording key=\(key)"
            )
            throw error
        }
    }

    /// Stops and saves every recording still running, so a flow that ends never leaves a recorder behind.
    public func stopActiveRecordings() async -> [Result<SavedVideo, any Error>] {
        var outcomes: [Result<SavedVideo, any Error>] = []
        for key in activeRecordings.keys.sorted() {
            guard let stop = beginStoppingRecording(key: key, stoppedBy: "run_end") else { continue }
            let outcome = await stop.value
            outcomes.append(outcome.mapError { $0 as any Error })
            activeRecordings[key] = nil
        }
        return outcomes
    }

    private func expireRecording(key: String, sessionID: String) {
        guard activeRecordings[key]?.session.id == sessionID else { return }
        recordingLogger.info("Recording reached max_seconds", context: "key=\(key)")
        _ = beginStoppingRecording(key: key, stoppedBy: "max_seconds")
    }

    /// The one stop task for `key`'s recording, started on first use.
    private func beginStoppingRecording(
        key: String,
        stoppedBy: String
    ) -> Task<Result<SavedVideo, ToolExecutionError>, Never>? {
        guard var active = activeRecordings[key] else { return nil }
        if let stop = active.stop {
            return stop
        }
        active.autoStop?.cancel()
        let driver = active.driver
        let sessionID = active.session.id
        let output = active.output
        let stop = Task { () -> Result<SavedVideo, ToolExecutionError> in
            do {
                let path = try await driver.stopRecording(sessionID: sessionID)
                return try .success(NativeVideo.save(recordingAt: path, to: output))
            } catch let error as ToolExecutionError {
                return .failure(error)
            } catch {
                return .failure(ToolExecutionError(code: "recording_failed", message: "Recording failed: \(error)"))
            }
        }
        active.stop = stop
        active.stoppedBy = stoppedBy
        activeRecordings[key] = active
        return stop
    }
}
