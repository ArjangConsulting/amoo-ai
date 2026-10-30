import AmooCore
@testable import CLI
import Foundation
import XCTest

private actor VideoRecordingLog {
    private(set) var events: [String] = []

    func start() -> RecordingSession {
        events.append("start")
        return RecordingSession(id: "recording", deviceID: "device")
    }

    func stop(_ id: String) -> String {
        events.append("stop:\(id)")
        return "/tmp/recording.mp4"
    }

    func wait(_ duration: TimeInterval) {
        events.append("wait:\(duration)")
    }
}

final class DeviceVideoRecordingTests: XCTestCase {
    func testRequiresBoundedFiniteDurationAndOutput() throws {
        for duration in ["0", "-1", "61", "nan", "inf", "invalid"] {
            XCTAssertThrowsError(try DeviceVideoRecordingOptions(arguments: [
                "duration_seconds": duration,
                "output": "/tmp/clip.mp4"
            ]))
        }
        XCTAssertThrowsError(try DeviceVideoRecordingOptions(arguments: [:]))
        let options = try DeviceVideoRecordingOptions(arguments: ["output": "/tmp/clip.mp4"])
        XCTAssertEqual(options.duration, 5)
        XCTAssertEqual(options.output.path, "/tmp/clip.mp4")
    }

    func testStopsTheSameRecordingAfterTheRequestedDuration() async throws {
        let log = VideoRecordingLog()
        let path = try await captureDeviceVideo(
            duration: 3,
            start: { await log.start() },
            stop: { await log.stop($0) },
            wait: { await log.wait($0) }
        )
        let events = await log.events
        XCTAssertEqual(path, "/tmp/recording.mp4")
        XCTAssertEqual(events, ["start", "wait:3.0", "stop:recording"])
    }

    func testCancellationStillStopsTheNativeRecorder() async {
        let log = VideoRecordingLog()
        do {
            _ = try await captureDeviceVideo(
                duration: 3,
                start: { await log.start() },
                stop: { await log.stop($0) },
                wait: { _ in throw CancellationError() }
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let events = await log.events
        XCTAssertEqual(events, ["start", "stop:recording"])
    }

    func testCancelledTaskAllowsRecorderCleanupToFinish() async {
        let log = VideoRecordingLog()
        let capture = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await captureDeviceVideo(
                duration: 3,
                start: { await log.start() },
                stop: { id in
                    try Task.checkCancellation()
                    return await log.stop(id)
                },
                wait: { _ in try Task.checkCancellation() }
            )
        }
        do {
            _ = try await capture.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let events = await log.events
        XCTAssertEqual(events, ["start", "stop:recording"])
    }
}
