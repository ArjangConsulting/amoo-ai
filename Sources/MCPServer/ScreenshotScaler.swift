import AmooCore
import Foundation

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Downscales a captured screenshot before it reaches a client.
///
/// A full-resolution phone screenshot is enormous to hand to a model, and most of what an agent
/// asks a screenshot ("which screen is this", "did the sheet dismiss") survives a halving intact.
/// Scaling is best-effort: an unsupported platform or an undecodable image returns `nil` and the
/// caller keeps the original rather than failing the capture.
enum ScaleAuditStatus: String {
    case ok
    case mismatch
    case unchecked
}

enum ScreenshotScaler {
    static func scalingStatus(requested: Double?, scaled: Data?) -> String {
        if scaled != nil {
            return "applied"
        }
        return (requested ?? 1) < 1 ? "unavailable" : "not_requested"
    }

    /// Whether the delivered image is the size the reported scale implies.
    ///
    /// Gestures take points and the image is in pixels, so a client divides image coordinates by
    /// `pixels per point`. If the device or the host scaled to a different size than it reported
    /// (a clamp, an orientation swap, an older companion), that division lands taps off target
    /// with no error. Rounding differences of a pixel or two are expected and pass.
    struct ScaleAudit: Equatable {
        let status: ScaleAuditStatus
        /// Delivered pixels per point, measured from the image rather than the reported scale.
        let measuredPixelsPerPoint: Double?
    }

    static func audit(
        actual: (width: Int, height: Int)?,
        nominalWidth: Double,
        nominalHeight: Double,
        widthPoints: Double
    ) -> ScaleAudit {
        guard let actual, widthPoints > 0, nominalWidth > 0, nominalHeight > 0 else {
            return ScaleAudit(status: .unchecked, measuredPixelsPerPoint: nil)
        }
        let measured = Double(actual.width) / widthPoints
        let tolerance = 2.0
        let matches = abs(Double(actual.width) - nominalWidth) <= tolerance
            && abs(Double(actual.height) - nominalHeight) <= tolerance
        return ScaleAudit(status: matches ? .ok : .mismatch, measuredPixelsPerPoint: measured)
    }

    static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
        #else
        guard data.count >= 24, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { return nil }
        let width = data[16 ..< 20].reduce(0) { $0 * 256 + Int($1) }
        let height = data[20 ..< 24].reduce(0) { $0 * 256 + Int($1) }
        return width > 0 && height > 0 ? (width, height) : nil
        #endif
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    /// An RGB space to draw into: a grayscale, indexed or missing source space cannot back a
    /// premultiplied RGBA context, which made the scale silently fail and the full image ship.
    private static func drawableColorSpace(_ source: CGColorSpace?) -> CGColorSpace {
        if let source, source.model == .rgb {
            return source
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
    #endif

    static func scaled(_ data: Data, by scale: Double?, format: ImageFormat) -> Data? {
        guard let scale, scale > 0, scale < 1 else { return nil }

        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        let colorSpace = Self.drawableColorSpace(image.colorSpace)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }

        let type: CFString = format == .jpeg ? UTType.jpeg.identifier as CFString
            : UTType.png.identifier as CFString
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
        #else
        return nil
        #endif
    }
}
