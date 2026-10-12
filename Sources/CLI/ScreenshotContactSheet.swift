import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreText)
import CoreGraphics
import CoreText
import ImageIO
#endif

/// One captioned thumbnail in a contact sheet.
struct ContactSheetEntry {
    var caption: String
    var bitmap: ScreenshotBitmap
}

/// The grid a set of screenshots is laid out in: cell size and how many columns.
struct ContactSheetLayout: Equatable {
    var columns: Int
    var cellWidth: Int
    var cellHeight: Int
    var captionHeight: Int
    var padding: Int
    var rows: Int

    /// Cells are as wide as asked and as tall as the tallest screenshot scales to, so a phone and a
    /// tablet in one sheet are each shown whole.
    init(entries: [ContactSheetEntry], columns: Int, cellWidth: Int) {
        let columns = max(1, min(columns, max(1, entries.count)))
        self.columns = columns
        self.cellWidth = max(40, cellWidth)
        captionHeight = 28
        padding = 12
        rows = entries.isEmpty ? 0 : (entries.count + columns - 1) / columns
        let tallest = entries.map { Double($0.bitmap.height) / Double(max(1, $0.bitmap.width)) }.max() ?? 1
        cellHeight = Int((Double(self.cellWidth) * tallest).rounded(.up))
    }

    var sheetWidth: Int {
        padding + columns * (cellWidth + padding)
    }

    var sheetHeight: Int {
        padding + rows * (cellHeight + captionHeight + padding)
    }

    /// Top-left of cell `index`, in top-left-origin sheet coordinates.
    func origin(ofCell index: Int) -> (x: Int, y: Int) {
        let column = index % columns
        let row = index / columns
        return (padding + column * (cellWidth + padding), padding + row * (cellHeight + captionHeight + padding))
    }
}

#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreText)
enum ScreenshotContactSheet {
    /// Renders `entries` into one PNG: thumbnails in a grid, each captioned above it.
    static func render(_ entries: [ContactSheetEntry], columns: Int, cellWidth: Int) -> Data? {
        guard !entries.isEmpty else { return nil }
        let layout = ContactSheetLayout(entries: entries, columns: columns, cellWidth: cellWidth)
        guard let context = CGContext(
            data: nil,
            width: layout.sheetWidth,
            height: layout.sheetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.sheetWidth, height: layout.sheetHeight))

        for (index, entry) in entries.enumerated() {
            let origin = layout.origin(ofCell: index)
            guard let image = entry.bitmap.cgImage() else { continue }
            let scale = min(
                Double(layout.cellWidth) / Double(image.width),
                Double(layout.cellHeight) / Double(image.height)
            )
            let drawWidth = Double(image.width) * scale
            let drawHeight = Double(image.height) * scale
            // CGContext's origin is bottom-left; the layout is top-left.
            let top = origin.y + layout.captionHeight
            let flippedY = Double(layout.sheetHeight - top) - drawHeight
            context.draw(
                image,
                in: CGRect(
                    x: Double(origin.x) + (Double(layout.cellWidth) - drawWidth) / 2,
                    y: flippedY,
                    width: drawWidth,
                    height: drawHeight
                )
            )
            let placement = CaptionPlacement(
                x: origin.x,
                baselineFromTop: origin.y + 18,
                sheetHeight: layout.sheetHeight,
                width: layout.cellWidth
            )
            drawCaption(entry.caption, in: context, at: placement)
        }
        return context.makeImage().flatMap(ScreenshotBitmap.pngData(from:))
    }

    /// Where a caption sits: its left edge, its baseline measured from the top, and the width it may use.
    private struct CaptionPlacement {
        var x: Int
        var baselineFromTop: Int
        var sheetHeight: Int
        var width: Int
    }

    private static func drawCaption(_ text: String, in context: CGContext, at placement: CaptionPlacement) {
        let font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        // Truncate a long file name with an ellipsis rather than bleeding into the next cell.
        let token = CTLineCreateWithAttributedString(CFAttributedStringCreate(
            nil,
            "…" as CFString,
            attributes as CFDictionary
        ))
        let fitted = CTLineCreateTruncatedLine(line, Double(placement.width), .end, token) ?? line
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1))
        context.textPosition = CGPoint(
            x: Double(placement.x),
            y: Double(placement.sheetHeight - placement.baselineFromTop)
        )
        CTLineDraw(fitted, context)
    }
}
#endif
