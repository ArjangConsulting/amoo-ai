import AmooCore
import CoreGraphics
import Foundation
import ImageIO

enum ScreenshotAnnotator {
    private struct RGBColor {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    /// Colors keyed by issue prefix
    private static let issueColors: [(prefix: String, color: RGBColor)] = [
        ("missing_label", RGBColor(red: 1.0, green: 0.22, blue: 0.22)), // red
        ("generic_label", RGBColor(red: 1.0, green: 0.60, blue: 0.00)), // orange
        ("duplicate_label", RGBColor(red: 1.0, green: 0.85, blue: 0.00)) // yellow
    ]

    static func annotate(pngData: Data, issues: [ElementA11yIssue], viewportWidth: Double) -> Data? {
        guard !issues.isEmpty else { return pngData }

        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height

        let scale = viewportWidth > 0 ? Double(pixelWidth) / viewportWidth : 1.0

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CGContext origin is bottom-left; iOS screenshots are top-left, so flip.
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
        context.restoreGState()

        let lineWidth = max(2.0, CGFloat(scale) * 1.5)
        let badgeSide = max(6.0, CGFloat(scale) * 5)

        for issue in issues {
            guard let frame = issue.frame else { continue }
            let color = strokeColor(for: issue.issue)

            let rect = CGRect(
                x: frame.x * scale,
                y: frame.y * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )

            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.stroke(rect)

            // Small filled corner badge so the issue is visible even on small elements
            let badge = CGRect(x: rect.minX, y: rect.minY, width: badgeSide, height: badgeSide)
            context.setFillColor(color)
            context.fill(badge)
        }

        guard let annotatedImage = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, annotatedImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output as Data
    }

    private static func strokeColor(for issue: String) -> CGColor {
        for (prefix, color) in issueColors where issue.hasPrefix(prefix) {
            return CGColor(red: color.red, green: color.green, blue: color.blue, alpha: 1.0)
        }
        // purple fallback for any future issue types
        return CGColor(red: 0.55, green: 0.0, blue: 1.0, alpha: 1.0)
    }
}
