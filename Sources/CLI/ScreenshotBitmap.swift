import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// A decoded screenshot: top-left origin, 8-bit RGBA, rows packed with no padding.
struct ScreenshotBitmap: Equatable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A bitmap of one opaque grey level (white by default) — for tests and diff overlays.
    init(width: Int, height: Int, grey: UInt8 = 255) {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = grey
            pixels[index + 1] = grey
            pixels[index + 2] = grey
        }
        self.init(width: width, height: height, pixels: pixels)
    }
}

/// How two same-sized screenshots differ.
struct ScreenshotDifference: Equatable {
    var changedPixels: Int
    var totalPixels: Int
    /// 0...1 share of pixels that changed by more than the tolerance.
    var ratio: Double {
        totalPixels == 0 ? 0 : Double(changedPixels) / Double(totalPixels)
    }
}

enum ScreenshotComparison {
    /// Counts pixels where any colour channel moves by more than `tolerance` (0...255).
    ///
    /// A small tolerance absorbs anti-aliasing and compression noise so only real UI changes count;
    /// alpha is ignored because a screenshot is opaque.
    static func difference(
        _ baseline: ScreenshotBitmap,
        _ current: ScreenshotBitmap,
        tolerance: Int = 8
    ) -> ScreenshotDifference? {
        guard baseline.width == current.width, baseline.height == current.height else { return nil }
        var changed = 0
        for index in stride(from: 0, to: baseline.pixels.count, by: 4)
            where Self.differs(baseline.pixels, current.pixels, at: index, tolerance: tolerance) {
            changed += 1
        }
        return ScreenshotDifference(changedPixels: changed, totalPixels: baseline.width * baseline.height)
    }

    /// The baseline dimmed, with every changed pixel painted red — what a reviewer looks at.
    static func overlay(
        _ baseline: ScreenshotBitmap,
        _ current: ScreenshotBitmap,
        tolerance: Int = 8
    ) -> ScreenshotBitmap? {
        guard baseline.width == current.width, baseline.height == current.height else { return nil }
        var output = baseline
        for index in stride(from: 0, to: baseline.pixels.count, by: 4) {
            if differs(baseline.pixels, current.pixels, at: index, tolerance: tolerance) {
                output.pixels[index] = 255
                output.pixels[index + 1] = 0
                output.pixels[index + 2] = 0
            } else {
                for channel in 0 ..< 3 {
                    output.pixels[index + channel] = UInt8((Int(baseline.pixels[index + channel]) + 3 * 255) / 4)
                }
            }
            output.pixels[index + 3] = 255
        }
        return output
    }

    private static func differs(_ lhs: [UInt8], _ rhs: [UInt8], at index: Int, tolerance: Int) -> Bool {
        for channel in 0 ..< 3 where abs(Int(lhs[index + channel]) - Int(rhs[index + channel])) > tolerance {
            return true
        }
        return false
    }
}

#if canImport(CoreGraphics) && canImport(ImageIO)
extension ScreenshotBitmap {
    /// Decodes an image file, or `nil` when it is not a readable image.
    static func load(from url: URL) -> Self? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return Self(image: image)
    }

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    func cgImage() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    func pngData() -> Data? {
        guard let image = cgImage() else { return nil }
        return Self.pngData(from: image)
    }

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
#endif
