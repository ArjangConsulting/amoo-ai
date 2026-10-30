import AmooCore
import AmooLogging
import CompanionProtocol
import Foundation
import MCP

private let videoRecordingLogger = AmooLogger.forType(DeviceVideoRecordingOptions.self)

func runDeviceVideoCommand(
    options: DeviceCommandOptions,
    driver: any PlatformDriver,
    companion: GRPCCompanionClient
) async -> CLIResult {
    let result = await runDeviceVideoRecording(options: options, driver: driver)
    await companion.shutdown()
    return result
}

struct DeviceVideoRecordingOptions: Equatable {
    let duration: TimeInterval
    let output: URL

    init(arguments: [String: String]) throws {
        guard let duration = TimeInterval(arguments["duration_seconds"] ?? "5"),
              duration.isFinite, (1 ... 60).contains(duration)
        else {
            throw DeviceVideoRecordingError.invalidDuration
        }
        guard let output = arguments["output"], !output.isEmpty else {
            throw DeviceVideoRecordingError.missingOutput
        }
        self.duration = duration
        self.output = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
    }
}

enum DeviceVideoRecordingError: Error, CustomStringConvertible {
    case invalidDuration
    case missingOutput
    case outputExists(String)
    case emptyRecording

    var description: String {
        switch self {
        case .invalidDuration: "duration_seconds must be a finite number from 1 to 60."
        case .missingOutput: "output is required for native video recording."
        case let .outputExists(path): "Recording output already exists: \(path)"
        case .emptyRecording: "The device returned an empty video recording."
        }
    }
}

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

func runDeviceVideoRecording(options: DeviceCommandOptions, driver: any PlatformDriver) async -> CLIResult {
    do {
        let recording = try DeviceVideoRecordingOptions(arguments: options.arguments)
        guard !FileManager.default.fileExists(atPath: recording.output.path) else {
            throw DeviceVideoRecordingError.outputExists(recording.output.path)
        }
        videoRecordingLogger.info("Starting native video recording", context: "platform=\(options.platform.rawValue)")
        let path = try await captureDeviceVideo(
            duration: recording.duration,
            start: { try await driver.startRecording() },
            stop: { try await driver.stopRecording(sessionID: $0) }
        )
        let source = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            throw DeviceVideoRecordingError.emptyRecording
        }
        try FileManager.default.createDirectory(
            at: recording.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: recording.output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recording.output.path)
        try? FileManager.default.removeItem(at: source)
        videoRecordingLogger.info("Native video recording saved", context: "platform=\(options.platform.rawValue)")
        return deviceCommandResult(
            options: options,
            content: "Native video saved to \(recording.output.path). Frame rate depends on the device encoder.",
            isError: false,
            structured: .object([
                "saved_path": .string(recording.output.path),
                "duration_seconds": .double(recording.duration),
                "byte_count": .int(size.intValue),
                "capture_method": .string("native_screen_recording")
            ])
        )
    } catch {
        videoRecordingLogger.error("Native video recording failed", error: error)
        return deviceCommandResult(
            options: options,
            content: "record_video failed: \(error)",
            isError: true,
            structured: nil
        )
    }
}
