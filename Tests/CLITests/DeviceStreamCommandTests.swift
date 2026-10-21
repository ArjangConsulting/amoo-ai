import AmooCore
@testable import CLI
import Foundation
import TestCommons
import XCTest

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DeviceStreamEvent] = []

    var events: [DeviceStreamEvent] {
        lock.withLock { stored }
    }

    func append(_ event: DeviceStreamEvent) {
        lock.withLock { stored.append(event) }
    }
}

private struct CaptureFailure: Error {}

/// The smallest byte string `pngDimensions` reads: signature, IHDR length/type, width, height.
private func pngHeader(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
    bytes += Array("IHDR".utf8)
    bytes += withUnsafeBytes(of: width.bigEndian, Array.init)
    bytes += withUnsafeBytes(of: height.bigEndian, Array.init)
    return Data(bytes)
}

final class DeviceStreamCommandTests: XCTestCase {
    // MARK: - Parsing

    func testDefaults() throws {
        let options = try parseDeviceStreamOptions(args: []).get()
        XCTAssertEqual(options, DeviceStreamOptions())
        XCTAssertEqual(options.platform, .ios)
        XCTAssertEqual(options.framesPerSecond, 6)
        XCTAssertEqual(options.maxPixelSize, 800)
        XCTAssertNil(options.outputDirectory)
    }

    func testParsesEveryFlag() throws {
        let options = try parseDeviceStreamOptions(args: [
            "--platform", "android", "--device", "emulator-5554", "--fps", "2.5",
            "--max-size", "0", "--out", "/tmp/frames", "--frames", "3"
        ]).get()
        XCTAssertEqual(options.platform, .android)
        XCTAssertEqual(options.deviceID, "emulator-5554")
        XCTAssertEqual(options.framesPerSecond, 2.5)
        XCTAssertEqual(options.maxPixelSize, 0)
        XCTAssertEqual(options.outputDirectory?.path, "/tmp/frames")
        XCTAssertEqual(options.frameLimit, 3)
    }

    func testRejectsBadValuesAndUnknownFlags() {
        XCTAssertEqual(
            parseDeviceStreamOptions(args: ["--fps", "0"]),
            .failure(.invalidValue(flag: "--fps", value: "0"))
        )
        XCTAssertEqual(
            parseDeviceStreamOptions(args: ["--fps", "60"]),
            .failure(.invalidValue(flag: "--fps", value: "60"))
        )
        XCTAssertEqual(
            parseDeviceStreamOptions(args: ["--max-size", "10"]),
            .failure(.invalidValue(flag: "--max-size", value: "10"))
        )
        XCTAssertEqual(
            parseDeviceStreamOptions(args: ["--frames", "0"]),
            .failure(.invalidValue(flag: "--frames", value: "0"))
        )
        XCTAssertEqual(parseDeviceStreamOptions(args: ["--device"]), .failure(.missingValue("--device")))
        XCTAssertEqual(parseDeviceStreamOptions(args: ["--device", "--fps"]), .failure(.missingValue("--device")))
        XCTAssertEqual(parseDeviceStreamOptions(args: ["--platform", "web"]), .failure(.unknownPlatform("web")))
        XCTAssertEqual(parseDeviceStreamOptions(args: ["--json"]), .failure(.unknownFlag("--json")))
    }

    // MARK: - PNG helpers

    func testReadsPNGDimensionsFromTheHeader() throws {
        let size = try XCTUnwrap(pngDimensions(pngHeader(width: 1179, height: 2556)))
        XCTAssertEqual(size.width, 1179)
        XCTAssertEqual(size.height, 2556)
        XCTAssertNil(pngDimensions(Data("not a png at all, really".utf8)))
        XCTAssertNil(pngDimensions(Data()))
    }

    func testDownscaleLeavesSmallOrUnscaledFramesAlone() {
        let header = pngHeader(width: 400, height: 800)
        XCTAssertEqual(downscaledPNG(header, maxPixelSize: 800), header)
        XCTAssertEqual(downscaledPNG(header, maxPixelSize: 0), header)
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    func testDownscaleFitsTheLongestSide() throws {
        let png = try XCTUnwrap(ScreenshotBitmap(width: 300, height: 600).pngData())
        let scaled = downscaledPNG(png, maxPixelSize: 200)
        let size = try XCTUnwrap(pngDimensions(scaled))
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 200)
    }
    #endif

    // MARK: - Streaming

    func testStreamsTheRequestedFramesThroughTheRing() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let log = EventLog()
        let frame = pngHeader(width: 10, height: 20)
        var options = DeviceStreamOptions()
        options.deviceID = "SIM-1"
        options.framesPerSecond = 30
        options.frameLimit = DeviceFrameStreamer.ringSize + 1
        let streamer = DeviceFrameStreamer(
            options: options,
            directory: scratch.url,
            capture: { frame },
            emit: log.append
        )

        let exitCode = await streamer.run()

        XCTAssertEqual(exitCode, 0)
        let events = log.events
        XCTAssertEqual(events.first, DeviceStreamEvent(
            event: "started",
            schema: 1,
            platform: "ios",
            device: "SIM-1",
            directory: scratch.url.path
        ))
        XCTAssertEqual(events.last, DeviceStreamEvent(event: "stopped", frames: DeviceFrameStreamer.ringSize + 1))
        let frames = events.filter { $0.event == "frame" }
        XCTAssertEqual(frames.map(\.frame), Array(0 ... DeviceFrameStreamer.ringSize))
        XCTAssertEqual(frames.first?.width, 10)
        XCTAssertEqual(frames.first?.height, 20)
        XCTAssertEqual(frames.last?.path, scratch.url.appending(path: "frame-0.png").path)
        let files = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).sorted()
        XCTAssertEqual(files, (0 ..< DeviceFrameStreamer.ringSize).map { "frame-\($0).png" })
        XCTAssertEqual(try Data(contentsOf: scratch.url.appending(path: "frame-0.png")), frame)
    }

    func testStopsWithAnErrorAfterRepeatedCaptureFailures() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let log = EventLog()
        var options = DeviceStreamOptions()
        options.framesPerSecond = 30
        let streamer = DeviceFrameStreamer(
            options: options,
            directory: scratch.url,
            capture: { throw CaptureFailure() },
            emit: log.append
        )

        let exitCode = await streamer.run()

        XCTAssertEqual(exitCode, 1)
        let events = log.events
        XCTAssertEqual(events.filter { $0.event == "error" }.count, DeviceFrameStreamer.maxConsecutiveFailures)
        XCTAssertEqual(events.last?.event, "stopped")
        XCTAssertEqual(events.last?.frames, 0)
        XCTAssertNotNil(events.last?.message)
    }

    func testStopsWhenTheParentGoesAway() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let log = EventLog()
        let streamer = DeviceFrameStreamer(
            options: DeviceStreamOptions(),
            directory: scratch.url,
            capture: { XCTFail("captured after the parent left"); return Data() },
            emit: log.append,
            shouldContinue: { false }
        )

        let exitCode = await streamer.run()

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(log.events.map(\.event), ["started", "stopped"])
    }

    func testCancellationEndsTheStream() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let log = EventLog()
        let frame = pngHeader(width: 1, height: 1)
        var options = DeviceStreamOptions()
        options.framesPerSecond = 0.1
        let streamer = DeviceFrameStreamer(
            options: options,
            directory: scratch.url,
            capture: { frame },
            emit: log.append
        )

        let task = Task { await streamer.run() }
        _ = try await waitUntil(timeout: .seconds(5), operation: { log.events.count }, matching: { $0 >= 2 })
        task.cancel()
        let exitCode = await task.value

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(log.events.map(\.event), ["started", "frame", "stopped"])
    }

    func testEventsEncodeAsOneCompactLineWithoutAbsentFields() {
        let line = renderJSON(DeviceStreamEvent(
            event: "frame",
            frame: 3,
            path: "/f/frame-3.png",
            elapsedMilliseconds: 12
        ))
        XCTAssertEqual(line, #"{"elapsed_ms":12,"event":"frame","frame":3,"path":"/f/frame-3.png"}"#)
    }

    func testStartedEventCarriesTheSchemaVersion() {
        let line = renderJSON(DeviceStreamEvent(event: "started", schema: DeviceStreamEvent.schemaVersion))
        XCTAssertEqual(line, #"{"event":"started","schema":1}"#)
        XCTAssertTrue(renderDeviceStreamHelp().contains(#""schema":1"#))
    }

    func testDeviceHelpPointsAtStream() {
        XCTAssertTrue(renderDeviceHelp().contains("amoo device stream --help"))
        XCTAssertTrue(renderDeviceStreamHelp().contains("--max-size"))
    }

    func testStreamHelpFlagReturnsStreamHelpNotDeviceHelp() async {
        for flag in ["--help", "-h", "help"] {
            let result = await CLIApp().run(args: ["device", "stream", flag])
            XCTAssertEqual(result.exitCode, 0, flag)
            XCTAssertTrue(result.output.hasPrefix("Usage: amoo device stream"), flag)
        }
        let device = await CLIApp().run(args: ["device", "--help"])
        XCTAssertTrue(device.output.contains("amoo device stream --help"))
    }
}
