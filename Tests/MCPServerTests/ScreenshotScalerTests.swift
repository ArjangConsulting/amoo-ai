import AmooCore
import CoreGraphics
import Foundation
import ImageIO
@testable import MCPServer
import UniformTypeIdentifiers
import XCTest

final class ScreenshotScalerTests: XCTestCase {
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
