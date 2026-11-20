#if canImport(CoreGraphics)
import AmooCore
@testable import AmooTools
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// `take_screenshot` with a selector returns only that element, so a question about one control
/// costs its pixels instead of the whole screen's.
final class ScreenshotCropTests: XCTestCase {
    /// A 100x200-point screen at 3x with one button at (20, 40, 50, 30) points. `framesPerUnit` 3
    /// reports frames in pixels, as Android does.
    private actor ButtonScreenDriver: PlatformDriver {
        let framesPerUnit: Double

        init(framesPerUnit: Double) {
            self.framesPerUnit = framesPerUnit
        }

        func takeScreenshot(format: ImageFormat) async throws -> ScreenshotData {
            try await takeScreenshot(ScreenshotRequestOptions(format: format))
        }

        func takeScreenshot(_: ScreenshotRequestOptions) async throws -> ScreenshotData {
            let geometry = ScreenSize(
                widthPoints: 100 * framesPerUnit,
                heightPoints: 200 * framesPerUnit,
                widthPixels: 300,
                heightPixels: 600,
                scale: 3 / framesPerUnit
            )
            return try ScreenshotData(bytes: Self.png(width: 300, height: 600), density: 3, geometry: geometry)
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            let button = ElementInfo(
                id: "save_button",
                label: "Save",
                type: .button,
                frame: Rect(
                    x: 20 * framesPerUnit, y: 40 * framesPerUnit, width: 50 * framesPerUnit, height: 30 * framesPerUnit
                )
            )
            let offscreen = ElementInfo(
                id: "footer",
                label: "Footer",
                type: .other,
                frame: Rect(x: 0, y: 900 * framesPerUnit, width: 100 * framesPerUnit, height: 40 * framesPerUnit)
            )
            return [button, offscreen].filter { selector.id == nil || selector.id == $0.id }
        }

        func elementGeometry() async throws -> ElementGeometry? {
            ElementGeometry(unit: framesPerUnit == 1 ? "points" : "dp", framesPerUnit: framesPerUnit)
        }

        func currentApp() async throws -> CurrentApp {
            CurrentApp(bundleID: "com.example.jot", targetBundleID: "com.example.jot")
        }

        static func png(width: Int, height: Int) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
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

    private func capture(
        framesPerUnit: Double,
        _ arguments: [String: String]
    ) async throws -> (result: ToolResult, fields: [String: Value]) {
        let executor = DriverToolExecutor(driver: ButtonScreenDriver(framesPerUnit: framesPerUnit))
        var arguments = arguments
        arguments["settle_timeout_ms"] = "0"
        let result = await executor.execute(toolName: "take_screenshot", arguments: arguments)
        let fields = result.structuredContent?.objectValue ?? [:]
        addTeardownBlock {
            fields["saved_path"]?.stringValue.map { try? FileManager.default.removeItem(atPath: $0) }
        }
        return (result, fields)
    }

    func testASelectorCropsToTheElementWithPadding() async throws {
        let (result, fields) = try await capture(framesPerUnit: 1, ["id": "save_button"])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(fields["width_pixels"]?.intValue, 66)
        XCTAssertEqual(fields["height_pixels"]?.intValue, 46)
        XCTAssertEqual(fields["crop_element"], .string("save_button"))
        let origin = try XCTUnwrap(fields["crop_origin_points"]?.objectValue)
        XCTAssertEqual(origin["x"]?.doubleValue, 12)
        XCTAssertEqual(origin["y"]?.doubleValue, 32)
        let saved = try XCTUnwrap(fields["saved_path"]?.stringValue)
        let data = try Data(contentsOf: URL(fileURLWithPath: saved))
        XCTAssertEqual(ScreenshotScaler.dimensions(data)?.width, 66)
        XCTAssertEqual(fields["byte_count"]?.intValue, data.count)
        XCTAssertTrue(result.content.contains("cropped to save_button"), result.content)
    }

    func testAndroidPixelFramesScaleOnceAndReportNativeGestureCoordinates() async throws {
        let (result, fields) = try await capture(framesPerUnit: 3, ["id": "save_button", "padding": "0"])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(fields["width_pixels"]?.intValue, 50)
        XCTAssertEqual(fields["height_pixels"]?.intValue, 30)
        let pixels = try XCTUnwrap(fields["crop_pixels"]?.objectValue)
        XCTAssertEqual(pixels["x"]?.intValue, 20)
        XCTAssertEqual(pixels["y"]?.intValue, 40)
        let origin = try XCTUnwrap(fields["crop_origin_points"]?.objectValue)
        XCTAssertEqual(origin["x"]?.doubleValue, 60)
        XCTAssertEqual(origin["y"]?.doubleValue, 120)
    }

    func testAMissingElementFailsInsteadOfReturningTheWholeScreen() async throws {
        let (result, fields) = try await capture(framesPerUnit: 1, ["id": "delete_button"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields["code"], .string("element_not_found"))
    }

    func testAnOffscreenElementFailsWithAScrollHint() async throws {
        let (result, fields) = try await capture(framesPerUnit: 1, ["id": "footer"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields["code"], .string("crop_unavailable"))
        XCTAssertTrue(result.content.contains("off-screen"), result.content)
    }

    func testUnrepresentablePaddingReportsAnError() async throws {
        let (result, fields) = try await capture(framesPerUnit: 1, ["id": "save_button", "padding": "1e100"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields["code"], .string("crop_unavailable"))
    }

    func testNoSelectorKeepsTheWholeScreen() async throws {
        let (result, fields) = try await capture(framesPerUnit: 1, [:])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(fields["width_pixels"]?.intValue, 100)
        XCTAssertNil(fields["crop_element"])
    }
}
#endif
