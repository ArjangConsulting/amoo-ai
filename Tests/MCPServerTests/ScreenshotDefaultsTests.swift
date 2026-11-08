// swiftlint:disable multiline_arguments
#if canImport(CoreGraphics)
import AmooCore
import CoreGraphics
import Foundation
import ImageIO
@testable import MCPServer
import UniformTypeIdentifiers
import XCTest

/// Records the capture options it receives; scales at the source only when `scalesOnDevice`.
private actor CaptureDriver: PlatformDriver {
    let scalesOnDevice: Bool
    let native: (width: Int, height: Int)
    let density: Double
    private(set) var requests: [ScreenshotRequestOptions] = []

    init(scalesOnDevice: Bool, native: (width: Int, height: Int) = (300, 600), density: Double = 3) {
        self.scalesOnDevice = scalesOnDevice
        self.native = native
        self.density = density
    }

    func takeScreenshot(format: ImageFormat) async throws -> ScreenshotData {
        try await takeScreenshot(ScreenshotRequestOptions(format: format))
    }

    func takeScreenshot(_ options: ScreenshotRequestOptions) async throws -> ScreenshotData {
        requests.append(options)
        let geometry = ScreenSize(
            widthPoints: Double(native.width) / density, heightPoints: Double(native.height) / density,
            widthPixels: Double(native.width), heightPixels: Double(native.height), scale: density
        )
        let fraction = options.pointResolution ? 1 / density : options.scale ?? 1
        guard scalesOnDevice, fraction < 1 else {
            return try ScreenshotData(
                bytes: Self.png(native.width, native.height),
                density: density,
                geometry: geometry
            )
        }
        let width = Int((Double(native.width) * fraction).rounded())
        let height = Int((Double(native.height) * fraction).rounded())
        return try ScreenshotData(
            bytes: Self.png(width, height), appliedScale: fraction, density: density, geometry: geometry
        )
    }

    static func png(_ width: Int, _ height: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0.4, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return [UInt8](output as Data)
    }
}

final class ScreenshotDefaultsTests: XCTestCase {
    func testDefaultCaptureIsSavedAtPointResolutionWithoutInlineImage() async throws {
        let driver = CaptureDriver(scalesOnDevice: true)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "take_screenshot", arguments: ["settle_timeout_ms": "0"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertNil(result.image)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        let path = try XCTUnwrap(fields["saved_path"]?.stringValue)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(path.contains("amoo-screenshots/adhoc/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(fields["width_pixels"]?.intValue, 100)
        XCTAssertEqual(fields["height_pixels"]?.intValue, 200)
        XCTAssertEqual(fields["scaling_status"], .string("applied_on_device"))
        XCTAssertEqual(fields["image_scale"]?.doubleValue ?? 0, 1.0 / 3, accuracy: 0.001)
        // One image pixel per point: image coordinates are gesture coordinates.
        XCTAssertEqual(fields["scale"]?.doubleValue ?? 0, 1, accuracy: 0.001)
        let requests = await driver.requests
        XCTAssertEqual(requests, [ScreenshotRequestOptions(pointResolution: true)])
    }

    func testHostScalesToPointsWhenTheDeviceReturnsNativePixels() async throws {
        let driver = CaptureDriver(scalesOnDevice: false)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "take_screenshot", arguments: ["settle_timeout_ms": "0", "return_image": "true"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertNotNil(result.image)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["width_pixels"]?.intValue, 100)
        XCTAssertEqual(fields["scaling_status"], .string("applied"))
        XCTAssertNil(fields["saved_path"])
    }

    func testExplicitScaleOneKeepsNativePixels() async throws {
        let driver = CaptureDriver(scalesOnDevice: true)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "take_screenshot", arguments: ["settle_timeout_ms": "0", "scale": "1"]
        )
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        defer { fields["saved_path"]?.stringValue.map { try? FileManager.default.removeItem(atPath: $0) } }
        XCTAssertEqual(fields["width_pixels"]?.intValue, 300)
        XCTAssertEqual(fields["image_scale"]?.doubleValue, 1)
        let requests = await driver.requests
        XCTAssertEqual(requests, [ScreenshotRequestOptions()])
    }

    func testSettlingProbesSmallFramesThenCapturesTheRequest() async throws {
        let driver = CaptureDriver(scalesOnDevice: true)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "take_screenshot", arguments: ["settle_timeout_ms": "1500"]
        )
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        defer { fields["saved_path"]?.stringValue.map { try? FileManager.default.removeItem(atPath: $0) } }
        XCTAssertEqual(fields["settled"], .bool(true))
        XCTAssertEqual(fields["width_pixels"]?.intValue, 100)
        let requests = await driver.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.prefix(2).map(\.scale), [0.25, 0.25])
        XCTAssertEqual(requests.last, ScreenshotRequestOptions(pointResolution: true))
    }
}
#endif

// swiftlint:enable multiline_arguments
