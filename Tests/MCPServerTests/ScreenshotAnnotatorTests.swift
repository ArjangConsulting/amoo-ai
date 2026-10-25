// swiftlint:disable multiline_arguments
#if canImport(CoreGraphics)
import AmooCore
import CoreGraphics
import Foundation
import ImageIO
@testable import MCPServer
import UniformTypeIdentifiers
import XCTest

final class ScreenshotAnnotatorTests: XCTestCase {
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
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
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

    func testAnnotateReturnsOriginalDataWhenNoIssues() {
        let png = makePNG(width: 50, height: 50)
        let result = ScreenshotAnnotator.annotate(pngData: png, issues: [], viewportWidth: 50)
        XCTAssertEqual(result, png)
    }

    func testAnnotateReturnsNilForUndecodableData() {
        let garbage = Data([0xFF, 0x00, 0x11])
        let issue = ElementA11yIssue(
            id: "1",
            label: "button",
            type: "button",
            issue: "missing_label",
            frame: Rect(x: 0, y: 0, width: 10, height: 10)
        )
        XCTAssertNil(ScreenshotAnnotator.annotate(pngData: garbage, issues: [issue], viewportWidth: 50))
    }

    func testAnnotateSkipsIssuesWithoutFrames() throws {
        let png = makePNG(width: 50, height: 50)
        let issue = ElementA11yIssue(id: "1", label: "button", type: "button", issue: "missing_label", frame: nil)
        let result = try XCTUnwrap(ScreenshotAnnotator.annotate(pngData: png, issues: [issue], viewportWidth: 50))
        XCTAssertFalse(result.isEmpty)
    }

    func testAnnotateProducesValidPNGWithIssues() throws {
        let png = makePNG(width: 100, height: 100)
        let issues = [
            ElementA11yIssue(
                id: "1",
                label: "button",
                type: "button",
                issue: "missing_label",
                frame: Rect(x: 10, y: 10, width: 20, height: 20)
            ),
            ElementA11yIssue(
                id: "2",
                label: "label",
                type: "text",
                issue: "generic_label",
                frame: Rect(x: 40, y: 40, width: 15, height: 15)
            ),
            ElementA11yIssue(
                id: "3",
                label: "dup",
                type: "text",
                issue: "duplicate_label_foo",
                frame: Rect(x: 60, y: 60, width: 10, height: 10)
            ),
            ElementA11yIssue(
                id: "4",
                label: "other",
                type: "text",
                issue: "some_unknown_issue",
                frame: Rect(x: 5, y: 5, width: 5, height: 5)
            )
        ]

        let result = try XCTUnwrap(ScreenshotAnnotator.annotate(pngData: png, issues: issues, viewportWidth: 100))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 100)
    }

    func testAnnotationPreservesImageOrientationAndUsesTopLeftScreenGeometry() throws {
        let width = 100
        let height = 100
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 30))
        let image = try XCTUnwrap(context.makeImage())
        let original = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(
            original,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(encoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let issue = ElementA11yIssue(
            id: "target", label: "", type: "button", issue: "missing_label",
            frame: Rect(x: 40, y: 10, width: 20, height: 20)
        )
        let annotated = try XCTUnwrap(ScreenshotAnnotator.annotate(
            pngData: original as Data, issues: [issue], viewportWidth: 100
        ))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(annotated as CFData, nil))
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rendered = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        rendered.draw(result, in: CGRect(x: 0, y: 0, width: width, height: height))
        let before = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let after = try XCTUnwrap(rendered.data).assumingMemoryBound(to: UInt8.self)
        for y in [5, 90] {
            let offset = (y * width + 5) * 4
            XCTAssertEqual(after[offset], before[offset])
            XCTAssertEqual(after[offset + 2], before[offset + 2])
        }
        let topBorder = (10 * width + 50) * 4
        let mirroredBorder = (89 * width + 50) * 4
        XCTAssertGreaterThan(after[topBorder], 100)
        XCTAssertEqual(after[mirroredBorder], before[mirroredBorder])
        XCTAssertEqual(after[mirroredBorder + 2], before[mirroredBorder + 2])
    }

    func testAnnotateHandlesZeroViewportWidth() throws {
        let png = makePNG(width: 30, height: 30)
        let issue = ElementA11yIssue(
            id: "1",
            label: "button",
            type: "button",
            issue: "missing_label",
            frame: Rect(x: 5, y: 5, width: 5, height: 5)
        )
        let result = try XCTUnwrap(ScreenshotAnnotator.annotate(pngData: png, issues: [issue], viewportWidth: 0))
        XCTAssertFalse(result.isEmpty)
    }
}
#endif

// swiftlint:enable multiline_arguments
