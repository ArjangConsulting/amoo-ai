import AmooCore
import Foundation
import MCP

/// A screenshot cut down to one element, so a visual question about a button costs that button's
/// pixels instead of a full screen's.
struct ScreenshotCrop {
    let data: Data
    let fields: [String: Value]
    let note: String
}

extension DriverToolExecutor {
    static let defaultCropPaddingPoints = 8.0

    /// Crops `data` to the element the call's selector names, when it names one.
    ///
    /// Element frames and gestures share coordinates (points on iOS, native pixels on Android).
    /// The result reports where the crop sits in gesture points, so a position read off the cropped
    /// image still converts to a tap.
    func screenshotCrop(
        _ data: Data,
        format: ImageFormat,
        pixelsPerPoint: Double?,
        arguments: [String: String],
        driver: any PlatformDriver
    ) async throws -> ScreenshotCrop? {
        guard let selector = try preferredSelector(arguments: arguments) else { return nil }
        guard let pixelsPerPoint, pixelsPerPoint > 0 else {
            throw ToolExecutionError(
                code: "crop_unavailable",
                message: "take_screenshot could not crop: the driver reported no screen geometry."
                    + " Capture without id, label or contains_text."
            )
        }
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        guard let element = try await resolveElement(
            selector: selector, driver: driver, appID: appID, pick: ElementPick.parse(arguments), missingIsNil: true
        ) else {
            throw ToolExecutionError(
                code: "element_not_found",
                message: "take_screenshot found no element matching \(Self.describeConstraints(selector)) to crop to.",
                extra: ["failure_kind": .string("selector_miss")]
            )
        }
        let name = element.id.isEmpty ? element.label : element.id
        guard let frame = element.frame else {
            throw ToolExecutionError(
                code: "crop_unavailable",
                message: "take_screenshot could not crop to \(name): the driver reported no frame for it."
            )
        }
        let rawPadding = arguments["padding"].flatMap(Double.init) ?? Self.defaultCropPaddingPoints
        let padding = max(0, rawPadding)
        guard rawPadding.isFinite,
              let region = Self.screenshotPixelRegion(frame: frame, pixelsPerPoint: pixelsPerPoint, padding: padding),
              let crop = ScreenshotScaler.cropped(data, to: region, format: format)
        else {
            throw ToolExecutionError(
                code: "crop_unavailable",
                message: "take_screenshot could not crop to \(name): the crop is off-screen, its geometry is invalid,"
                    + " or this host cannot decode the image. Scroll it into view, or capture the whole screen."
            )
        }
        let originX = Double(crop.region.x) / pixelsPerPoint
        let originY = Double(crop.region.y) / pixelsPerPoint
        let fields: [String: Value] = [
            "byte_count": .int(crop.data.count),
            "crop_element": .string(name),
            "crop_origin_points": .object(["x": .double(originX), "y": .double(originY)]),
            "crop_pixels": .object([
                "x": .int(crop.region.x), "y": .int(crop.region.y),
                "width": .int(crop.region.width), "height": .int(crop.region.height)
            ])
        ]
        let note = " — cropped to \(name) (\(crop.region.width)x\(crop.region.height)px); a point in the image is"
            + " (\(geometryNumber(originX)) + x / \(pixelsPerPoint.formatted()),"
            + " \(geometryNumber(originY)) + y / \(pixelsPerPoint.formatted())) in gesture points"
        return ScreenshotCrop(data: crop.data, fields: fields, note: note)
    }

    private static func screenshotPixelRegion(
        frame: Rect, pixelsPerPoint: Double, padding: Double
    ) -> PixelRegion? {
        let x = (frame.x - padding) * pixelsPerPoint
        let y = (frame.y - padding) * pixelsPerPoint
        let width = (frame.width + padding * 2) * pixelsPerPoint
        let height = (frame.height + padding * 2) * pixelsPerPoint
        guard let left = Int(exactly: x.rounded(.down)), let top = Int(exactly: y.rounded(.down)),
              let width = Int(exactly: width.rounded(.up)), width > 0,
              let height = Int(exactly: height.rounded(.up)), height > 0 else { return nil }
        return PixelRegion(x: left, y: top, width: width, height: height)
    }
}
