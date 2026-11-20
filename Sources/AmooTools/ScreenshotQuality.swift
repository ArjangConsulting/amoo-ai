// swiftlint:disable multiline_arguments
import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Advisory pixel checks; a uniform frame can be legitimate and never establishes an app failure.
enum ScreenshotQuality {
    struct Assessment {
        let suspect: Bool?
        let reason: String
    }

    static func assess(_ data: Data) -> Assessment {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128
              ] as CFDictionary) else { return Assessment(suspect: true, reason: "undecodable_image") }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return Assessment(suspect: nil, reason: "analysis_unavailable") }
        return classify(pixels, total: Double(width * height))
        #else
        return Assessment(suspect: nil, reason: "analysis_unavailable")
        #endif
    }

    private static func classify(_ pixels: [UInt8], total: Double) -> Assessment {
        var black = 0
        var white = 0
        var transparent = 0
        var colors: [Int: Int] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
            if max(red, green, blue) <= 8 {
                black += 1
            }
            if min(red, green, blue) >= 247 {
                white += 1
            }
            if pixels[offset + 3] <= 8 {
                transparent += 1
            }
            colors[(red / 8) * 1024 + (green / 8) * 32 + blue / 8, default: 0] += 1
        }
        if Double(transparent) / total >= 0.985 {
            return Assessment(suspect: true, reason: "transparent_frame")
        }
        if Double(black) / total >= 0.985 {
            return Assessment(suspect: true, reason: "near_black_frame")
        }
        if Double(white) / total >= 0.985 {
            return Assessment(suspect: true, reason: "near_white_frame")
        }
        if Double(colors.values.max() ?? 0) / total >= 0.995 {
            return Assessment(suspect: true, reason: "uniform_frame")
        }
        return Assessment(suspect: false, reason: "content_detected")
    }
}

// swiftlint:enable multiline_arguments
