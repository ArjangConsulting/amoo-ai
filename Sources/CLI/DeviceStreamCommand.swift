import AmooCore
import AmooLogging
import Foundation
import ProcessRunner
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

private let streamLogger = AmooLogger.forType(DeviceFrameStreamer.self)

// MARK: - Options

/// `amoo device stream`: a host-side frame producer for live views (the `amoo-live` Claude Code
/// pane). It captures with simctl / devicectl / adb, never through the companion, takes no device
/// lease and records nothing into a session, so it can watch a device another session drives.
struct DeviceStreamOptions: Equatable {
    var platform: Platform = .ios
    var deviceID: String?
    var framesPerSecond: Double = 6
    /// Longest side of a written frame, in pixels; `0` keeps the captured size.
    var maxPixelSize = 800
    /// Where frames are written; `nil` uses a fresh temporary directory removed on exit.
    var outputDirectory: URL?
    /// Stop after this many frames; `nil` streams until signalled.
    var frameLimit: Int?
}

enum DeviceStreamParseError: Error, CustomStringConvertible, Equatable {
    case missingValue(String)
    case invalidValue(flag: String, value: String)
    case unknownPlatform(String)
    case unknownFlag(String)

    var description: String {
        switch self {
        case let .missingValue(flag):
            "\(flag) needs a value.\n\n" + renderDeviceStreamHelp()
        case let .invalidValue(flag, value):
            "Invalid value '\(value)' for \(flag).\n\n" + renderDeviceStreamHelp()
        case let .unknownPlatform(value):
            "Unknown platform '\(value)'. Expected 'ios' or 'android'."
        case let .unknownFlag(flag):
            "Unknown flag '\(flag)'.\n\n" + renderDeviceStreamHelp()
        }
    }
}

func renderDeviceStreamHelp() -> String {
    """
    Usage: amoo device stream [--platform ios|android] [--device <id>] [--fps <n>]
                              [--max-size <px>] [--out <dir>] [--frames <n>]

    Streams screenshots of a simulator, emulator or device as PNG files, for live views such as
    the amoo-live Claude Code pane. Capture runs on the host (simctl, devicectl, adb): it does not
    use the companion, take a device lease, or record into a session.

      --platform     ios (default) or android.
      --device       Simulator UDID, device id or adb serial. iOS defaults to the booted simulator.
      --fps          Frames per second to aim for, 0.1–30 (default 6). Capture speed caps it: about
                     2 fps on simulators, ~1 fps on physical iOS devices.
      --max-size     Downscale so the longest side is at most this many pixels (default 800;
                     0 keeps the captured size).
      --out          Directory to write frames into (default: a temporary directory removed on exit).
      --frames       Stop after this many frames (default: run until SIGINT/SIGTERM).

    Frames rotate through frame-0.png … frame-3.png, each written atomically. Stdout carries one
    JSON object per line:
      {"event":"started","schema":1,"platform":"ios","device":"…","directory":"…"}
      {"event":"frame","frame":12,"path":"…/frame-0.png","width":369,"height":800,"elapsed_ms":2104}
      {"event":"error","message":"…"}
      {"event":"stopped","frames":40}
    It also stops when its parent process exits, or after 10 capture failures in a row (exit 1).
    """
}

// swiftlint:disable:next cyclomatic_complexity - one flat case per flag.
func parseDeviceStreamOptions(args: [String]) -> Result<DeviceStreamOptions, DeviceStreamParseError> {
    var options = DeviceStreamOptions()
    var remaining = args[...]
    while let flag = remaining.popFirst() {
        guard ["--platform", "--device", "--fps", "--max-size", "--out", "--frames"].contains(flag) else {
            return .failure(.unknownFlag(flag))
        }
        guard let value = remaining.popFirst(), !value.hasPrefix("--") else {
            return .failure(.missingValue(flag))
        }
        switch flag {
        case "--platform":
            guard let platform = Platform(rawValue: value.lowercased()) else {
                return .failure(.unknownPlatform(value))
            }
            options.platform = platform
        case "--device":
            options.deviceID = value
        case "--fps":
            guard let fps = Double(value), fps >= 0.1, fps <= 30 else {
                return .failure(.invalidValue(flag: flag, value: value))
            }
            options.framesPerSecond = fps
        case "--max-size":
            guard let size = Int(value), size == 0 || size >= 64 else {
                return .failure(.invalidValue(flag: flag, value: value))
            }
            options.maxPixelSize = size
        case "--out":
            options.outputDirectory = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        case "--frames":
            guard let limit = Int(value), limit >= 1 else {
                return .failure(.invalidValue(flag: flag, value: value))
            }
            options.frameLimit = limit
        default:
            return .failure(.unknownFlag(flag))
        }
    }
    if options.platform == .android, options.deviceID == "booted" {
        options.deviceID = nil
    }
    return .success(options)
}

// MARK: - Events

/// One line of `amoo device stream` output. Absent fields are omitted from the JSON.
struct DeviceStreamEvent: Encodable, Equatable {
    /// Version of the event vocabulary, sent on `started` so a reader can tell what it is talking to.
    static let schemaVersion = 1

    var event: String
    var schema: Int?
    var platform: String?
    var device: String?
    var directory: String?
    var frame: Int?
    var path: String?
    var width: Int?
    var height: Int?
    var elapsedMilliseconds: Int?
    var frames: Int?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case event, schema, platform, device, directory, frame, path, width, height, frames, message
        case elapsedMilliseconds = "elapsed_ms"
    }
}

// MARK: - Streamer

/// Captures, downscales and writes frames at a steady pace, reporting each as a ``DeviceStreamEvent``.
///
/// Captures run one at a time. `simctl io screenshot` serializes overlapping captures, so running
/// several at once delivers no more frames, only bursts with long pauses between them.
struct DeviceFrameStreamer {
    /// Frames rotate through this many files, so a reader holding the previous path keeps a whole image.
    static let ringSize = 4
    static let maxConsecutiveFailures = 10

    let options: DeviceStreamOptions
    let directory: URL
    let capture: @Sendable () async throws -> Data
    let emit: @Sendable (DeviceStreamEvent) -> Void
    var shouldContinue: @Sendable () -> Bool = { true }

    /// Streams until cancelled, `shouldContinue` turns false or the frame limit is reached.
    /// Returns the process exit code: 1 after too many consecutive capture failures.
    func run() async -> Int32 {
        let context = "action=stream platform=\(options.platform.rawValue) device=\(options.deviceID ?? "booted")"
        streamLogger.info("Device stream starting", context: context)
        emit(DeviceStreamEvent(
            event: "started",
            schema: DeviceStreamEvent.schemaVersion,
            platform: options.platform.rawValue,
            device: options.deviceID ?? (options.platform == .ios ? "booted" : nil),
            directory: directory.path
        ))

        let clock = ContinuousClock()
        let start = clock.now
        let interval = Swift.Duration.seconds(1 / options.framesPerSecond)
        var sink = FrameSink(
            directory: directory,
            frameLimit: options.frameLimit,
            emit: emit,
            elapsed: { milliseconds(clock.now - start) },
            context: context
        )

        var due = start
        while !Task.isCancelled, shouldContinue(), !sink.isFinished {
            if clock.now < due {
                do { try await Task.sleep(until: due, clock: clock) } catch { break }
            }
            due = clock.now + interval
            let outcome: Result<Data, any Error>
            do {
                outcome = try await .success(downscaledPNG(capture(), maxPixelSize: options.maxPixelSize))
            } catch {
                outcome = .failure(error)
            }
            guard !Task.isCancelled else { break }
            sink.accept(outcome)
        }

        streamLogger.info(
            "Device stream stopped",
            context: context + " frames=\(sink.written) failed=\(sink.hasFailed)"
        )
        emit(DeviceStreamEvent(
            event: "stopped",
            frames: sink.written,
            message: sink.hasFailed ? "\(Self.maxConsecutiveFailures) capture failures in a row" : nil
        ))
        return sink.hasFailed ? 1 : 0
    }
}

private func milliseconds(_ duration: Swift.Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
}

/// Writes and reports captured frames, and counts consecutive capture failures.
private struct FrameSink {
    private let directory: URL
    private let frameLimit: Int?
    private let emit: @Sendable (DeviceStreamEvent) -> Void
    private let elapsed: @Sendable () -> Int
    private let context: String
    private var consecutiveFailures = 0
    private(set) var written = 0
    private(set) var hasFailed = false

    init(
        directory: URL,
        frameLimit: Int?,
        emit: @escaping @Sendable (DeviceStreamEvent) -> Void,
        elapsed: @escaping @Sendable () -> Int,
        context: String
    ) {
        self.directory = directory
        self.frameLimit = frameLimit
        self.emit = emit
        self.elapsed = elapsed
        self.context = context
    }

    var isFinished: Bool {
        hasFailed || frameLimit.map { written >= $0 } ?? false
    }

    mutating func accept(_ outcome: Result<Data, any Error>) {
        switch outcome {
        case let .success(png):
            let url = directory.appending(path: "frame-\(written % DeviceFrameStreamer.ringSize).png")
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                fail(error)
                return
            }
            let size = pngDimensions(png)
            emit(DeviceStreamEvent(
                event: "frame",
                frame: written,
                path: url.path,
                width: size?.width,
                height: size?.height,
                elapsedMilliseconds: elapsed()
            ))
            written += 1
            consecutiveFailures = 0
        case let .failure(error):
            fail(error)
        }
    }

    private mutating func fail(_ error: any Error) {
        consecutiveFailures += 1
        streamLogger.error("Frame capture failed", error: error, context: context + " failures=\(consecutiveFailures)")
        emit(DeviceStreamEvent(event: "error", message: "\(error)"))
        if consecutiveFailures >= DeviceFrameStreamer.maxConsecutiveFailures {
            hasFailed = true
        }
    }
}

// MARK: - PNG helpers

/// Width and height from a PNG's IHDR chunk, or `nil` when `data` is not a PNG.
func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    let bytes = [UInt8](data.prefix(24))
    guard bytes.count == 24, Array(bytes[0 ..< 8]) == signature, bytes[12 ..< 16].elementsEqual("IHDR".utf8) else {
        return nil
    }
    func bigEndian(_ offset: Int) -> Int {
        bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
    }
    return (bigEndian(16), bigEndian(20))
}

/// Re-encodes `png` so its longest side is at most `maxPixelSize`. Returns the input unchanged when
/// it already fits, `maxPixelSize` is 0, or the platform has no image codecs (Linux).
func downscaledPNG(_ png: Data, maxPixelSize: Int) -> Data {
    guard maxPixelSize > 0, let size = pngDimensions(png), max(size.width, size.height) > maxPixelSize else {
        return png
    }
    #if canImport(CoreGraphics) && canImport(ImageIO)
    let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ] as CFDictionary
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
          let scaled = ScreenshotBitmap.pngData(from: image)
    else { return png }
    return scaled
    #else
    return png
    #endif
}

// MARK: - Execution

/// The host capture for the stream's device: simctl for simulators, devicectl for physical iOS
/// devices, adb for Android.
func makeDeviceFrameCapture(_ options: DeviceStreamOptions) async -> @Sendable () async throws -> Data {
    switch options.platform {
    case .ios:
        let deviceID = options.deviceID ?? "booted"
        if await DeviceSelector().isPhysicalDevice(deviceID: deviceID) {
            let devicectl = DeviceCtlRunner()
            return { try await devicectl.screenshot(device: deviceID) }
        }
        let simctl = SimctlRunner()
        return { try await simctl.screenshot(device: deviceID, format: .png) }
    case .android:
        let adb = ADBRunner()
        let serial = options.deviceID
        return { try await adb.screenshot(serial: serial) }
    }
}

func runDeviceStream(options: DeviceStreamOptions) async -> CLIResult {
    let directory: URL
    let ownsDirectory = options.outputDirectory == nil
    if let requested = options.outputDirectory {
        directory = requested
    } else {
        directory = FileManager.default.temporaryDirectory.appending(path: "amoo-stream-\(UUID().uuidString)")
    }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        streamLogger.error("Could not create stream directory", error: error, context: "action=stream")
        return CLIResult(output: "Could not create \(directory.path): \(error)", exitCode: 1)
    }
    defer {
        if ownsDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    let parent = getppid()
    let streamer = await DeviceFrameStreamer(
        options: options,
        directory: directory,
        capture: makeDeviceFrameCapture(options),
        emit: { event in
            FileHandle.standardOutput.write(Data((renderJSON(event) + "\n").utf8))
        },
        // A live view's host (an editor, Claude Code) may die without signalling us; reparenting
        // to launchd/init is the only notice an orphan gets.
        shouldContinue: { getppid() == parent }
    )

    let signals = CompanionSignalWaiter()
    let streaming = Task { await streamer.run() }
    let signalTask = Task {
        await signals.wait()
        if !Task.isCancelled {
            streaming.cancel()
        }
    }
    let exitCode = await streaming.value
    signalTask.cancel()
    signals.finish()
    return CLIResult(output: "", exitCode: exitCode)
}
