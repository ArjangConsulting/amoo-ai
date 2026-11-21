import AmooCore
@testable import AmooTools
import Foundation
import TestCommons
import XCTest

/// Minimal MP4 files: `ftyp`, `mdat`, then `moov/mvhd` at the end, the order simctl and screenrecord write.
enum VideoFixture {
    static func mp4(seconds: Double, version: UInt8 = 0, largeMdat: Bool = false) -> Data {
        let timescale: UInt32 = 600
        let duration = UInt64(seconds * Double(timescale))
        var mvhd: [UInt8] = [version, 0, 0, 0]
        if version == 1 {
            mvhd += bytes(UInt64(0)) + bytes(UInt64(0)) + bytes(timescale) + bytes(duration)
        } else {
            mvhd += bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(timescale) + bytes(UInt32(duration))
        }
        mvhd += [UInt8](repeating: 0, count: 80)
        let mvhdBox = box("mvhd", mvhd)
        let payload = [UInt8](repeating: 7, count: 32)
        let mdat = largeMdat
            ? bytes(UInt32(1)) + Array("mdat".utf8) + bytes(UInt64(16 + payload.count)) + payload
            : box("mdat", payload)
        return Data(box("ftyp", Array("isom".utf8) + bytes(UInt32(0x200))) + mdat + box("moov", mvhdBox))
    }

    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        bytes(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        (0 ..< 4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static func bytes(_ value: UInt64) -> [UInt8] {
        (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

final class VideoDurationTests: XCTestCase {
    func testReadsTheHeaderLengthOfEveryBoxLayout() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let cases: [(Data, Double)] = [
            (VideoFixture.mp4(seconds: 5), 5),
            (VideoFixture.mp4(seconds: 2.5, version: 1), 2.5),
            (VideoFixture.mp4(seconds: 4, largeMdat: true), 4)
        ]
        for (index, (data, expected)) in cases.enumerated() {
            let url = scratch.url.appending(path: "\(index).mp4")
            try data.write(to: url)
            XCTAssertEqual(try XCTUnwrap(VideoDuration.seconds(at: url)), expected, accuracy: 0.001)
        }
    }

    func testUnreadableVideoHasNoLength() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let url = scratch.url.appending(path: "junk.mp4")
        try Data([0xFF, 0x00, 0x01]).write(to: url)
        XCTAssertNil(VideoDuration.seconds(at: url))
        XCTAssertNil(VideoDuration.seconds(at: scratch.url.appending(path: "missing.mp4")))
    }

    func testRecordVideoReportsRequestedAndRecordedSeconds() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let output = scratch.url.appending(path: "short.mp4").path
        let executor = DriverToolExecutor(driver: MockDriver(), defaultPlatform: .ios)

        let result = await executor.execute(
            toolName: "record_video", arguments: ["output": output, "duration_seconds": "1"]
        )

        XCTAssertFalse(result.isError, result.content)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["requested_seconds"], .double(1))
        XCTAssertEqual(fields["recorded_seconds"], .double(5))
    }

    func testAStillScreenClipSaysWhyItIsShort() {
        let still = SavedVideo(path: "/tmp/still.mp4", byteCount: 177_806, recordedSeconds: 0).result()
        XCTAssertNotNil(still.structuredContent?.objectValue?["recording_note"]?.stringValue)
        XCTAssertTrue(still.content.contains("did not change"), still.content)

        let moving = SavedVideo(path: "/tmp/moving.mp4", byteCount: 905_811, recordedSeconds: 8.46).result()
        XCTAssertNil(moving.structuredContent?.objectValue?["recording_note"])
        XCTAssertEqual(moving.structuredContent?.objectValue?["recorded_seconds"], .double(8.46))
    }
}
