// swiftlint:disable multiline_arguments
#if canImport(CoreGraphics)
import AmooCore
import CoreGraphics
import Foundation
import ImageIO
@testable import MCPServer
import TestCommons
import TestSession
import UniformTypeIdentifiers
import XCTest

final class ScreenshotScalerTests: XCTestCase {
    func testSavedScaledScreenshotReportsActualDimensionsAndMeasuredBytesWithoutInlineImage() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let output = scratch.url.appending(path: "screen.png")
        let bootstrapper = MockSessionBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper)
        let session = try await manager.startSession(appID: "com.example.app", platform: .ios)
        let driver = await bootstrapper.lastDriver
        await driver?.setScreenshotFrames(Array(repeating: Array(makePNG(width: 200, height: 100)), count: 2))
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(
            toolName: "take_screenshot",
            arguments: [
                "session_id": session.id, "output": output.path, "return_image": "false",
                "scale": "0.5", "settle_timeout_ms": "0"
            ]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertNil(result.image)
        XCTAssertEqual(result.structuredContent?.objectValue?["capture_suspect"], .bool(true))
        XCTAssertNotNil(result.structuredContent?.objectValue?["foreground_app_id"])
        XCTAssertNotNil(result.structuredContent?.objectValue?["screen_state"])
        XCTAssertEqual(result.structuredContent?.objectValue?["width_pixels"]?.intValue, 100)
        XCTAssertEqual(result.structuredContent?.objectValue?["height_pixels"]?.intValue, 50)
        let metrics = await session.verificationMetrics
        XCTAssertEqual(metrics.clientCalls, 1)
        XCTAssertEqual(metrics.operations, 1)
        XCTAssertEqual(metrics.imageBytes, 0)
        XCTAssertEqual(metrics.imageDimensions, ["100x50"])
        XCTAssertEqual(metrics.evidenceImageBytes, try Data(contentsOf: output).count)
        let runReport = await executor.execute(toolName: "get_run_telemetry", arguments: [:])
        let costs = runReport.structuredContent?.objectValue?["metrics"]?.objectValue
        XCTAssertEqual(costs?["image_bytes"], .int(0))
        XCTAssertEqual(costs?["image_pixels"], .int(0))
        XCTAssertEqual(costs?["evidence_image_pixels"], .int(5000))
        XCTAssertEqual(costs?["evidence_image_bytes"]?.intValue, try Data(contentsOf: output).count)
        let inline = await executor.execute(toolName: "take_screenshot", arguments: [
            "session_id": session.id, "settle_timeout_ms": "0", "return_image": "true", "scale": "1"
        ])
        let afterInline = await executor.execute(toolName: "get_run_telemetry", arguments: [:])
        let inlineCosts = afterInline.structuredContent?.objectValue?["metrics"]?.objectValue
        XCTAssertEqual(inlineCosts?["image_bytes"]?.intValue, inline.image?.data.count)
        XCTAssertEqual(inlineCosts?["image_pixels"], .int(20000))
        XCTAssertGreaterThan(
            inlineCosts?["wire_response_bytes"]?.intValue ?? 0,
            inlineCosts?["text_payload_bytes"]?.intValue ?? 0
        )
    }

    func testQualityFlagsUniformFramesAndLeavesContentFramesUsable() throws {
        let uniform = makePNG(width: 200, height: 100)
        XCTAssertEqual(ScreenshotQuality.assess(uniform).suspect, true)
        XCTAssertEqual(ScreenshotQuality.assess(Data()).reason, "undecodable_image")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(ScreenshotQuality.assess(pngData(context)).reason, "near_black_frame")
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(ScreenshotQuality.assess(pngData(context)).reason, "near_white_frame")
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 60, y: 20, width: 80, height: 60))
        XCTAssertEqual(ScreenshotQuality.assess(pngData(context)).suspect, false)
    }

    private func pngData(_ context: CGContext) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func makePNG(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    func testScaledReturnsNilForOutOfRangeScale() {
        let png = makePNG(width: 100, height: 100)

        XCTAssertNil(ScreenshotScaler.scaled(png, by: nil, format: .png))
        XCTAssertNil(ScreenshotScaler.scaled(png, by: 0, format: .png))
        XCTAssertNil(ScreenshotScaler.scaled(png, by: -0.5, format: .png))
        XCTAssertNil(ScreenshotScaler.scaled(png, by: 1, format: .png))
        XCTAssertNil(ScreenshotScaler.scaled(png, by: 1.5, format: .png))
    }

    func testScaledReturnsNilForUndecodableData() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertNil(ScreenshotScaler.scaled(garbage, by: 0.5, format: .png))
    }

    func testScaledProducesSmallerPNG() throws {
        let png = makePNG(width: 200, height: 100)
        let scaled = try XCTUnwrap(ScreenshotScaler.scaled(png, by: 0.5, format: .png))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(scaled as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 50)
        let dimensions = try XCTUnwrap(ScreenshotScaler.dimensions(scaled))
        XCTAssertEqual(dimensions.width, 100)
        XCTAssertEqual(dimensions.height, 50)
    }

    func testScaledProducesJPEGWhenRequested() throws {
        let png = makePNG(width: 40, height: 40)
        let scaled = try XCTUnwrap(ScreenshotScaler.scaled(png, by: 0.5, format: .jpeg))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(scaled as CFData, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source))
        XCTAssertEqual(type as String, UTType.jpeg.identifier)
    }

    func testScaledReturnsNilWhenResultingDimensionsAreZero() {
        let png = makePNG(width: 1, height: 1)
        XCTAssertNil(ScreenshotScaler.scaled(png, by: 0.01, format: .png))
    }
}
#endif

// swiftlint:enable multiline_arguments
