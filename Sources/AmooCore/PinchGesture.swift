import Foundation

/// The two finger paths of a pinch around a centre point, fitted inside the bounds the gesture is
/// delivered in.
///
/// Fingers sit on a line through `center` on whichever axis has more room, mirror each other, and
/// move between `startRadius` and `endRadius`. A `scale` above 1 spreads them (zoom in); below 1
/// brings them together (zoom out). The radii are fitted so the fingers never leave `bounds` and
/// never come closer than ``minimumRadius``, which means a very large or very small `scale` is
/// clamped. ``effectiveScale`` reports the ratio actually performed.
///
/// Shared by the iOS companion (compiled into its UI-test bundle from this file), which synthesizes
/// the two touch paths directly, because XCUITest's `pinch(withScale:velocity:)` can only pinch
/// around an element's centre.
public struct PinchGesture: Sendable, Equatable {
    /// `scale` was not a finite positive number other than 1.
    public struct InvalidScale: Error, CustomStringConvertible {
        public let scale: Double

        public var description: String {
            "pinch scale must be a positive number other than 1 (above 1 zooms in, below 1 zooms out); got \(scale)"
        }
    }

    public enum Axis: Sendable, Equatable {
        case horizontal
        case vertical
    }

    /// Closest the fingers get to the centre. Two touches nearer than this read as one.
    public static let minimumRadius = 20.0
    /// Furthest the fingers get from the centre, so a pinch on a tablet stays a hand-sized gesture.
    public static let maximumRadius = 240.0
    /// Clearance kept between a finger and the edge of `bounds`.
    public static let edgeMargin = 8.0
    /// Duration when the caller gives no velocity.
    public static let defaultDurationSeconds = 0.6
    public static let durationRangeSeconds = 0.2 ... 3.0

    public let center: Point
    public let axis: Axis
    public let startRadius: Double
    public let endRadius: Double
    public let durationSeconds: Double

    /// Validates and fits a pinch. Throws when `scale` is not a finite positive number other than 1.
    ///
    /// - Parameters:
    ///   - center: Where the fingers meet. Moved inside `bounds` far enough to fit both fingers.
    ///   - scale: Ratio of finger separation at the end to the start.
    ///   - velocity: Scale change per second. Zero or negative means "use the default duration".
    ///   - bounds: The frame the gesture is delivered in, in the same space as `center`.
    public init(center: Point, scale: Double, velocity: Double, bounds: Rect) throws {
        guard scale.isFinite, scale > 0, scale != 1 else {
            throw InvalidScale(scale: scale)
        }
        let inset = Self.minimumRadius + Self.edgeMargin
        let fitted = Point(
            x: Self.clamp(center.x, lower: bounds.x + inset, upper: bounds.x + bounds.width - inset),
            y: Self.clamp(center.y, lower: bounds.y + inset, upper: bounds.y + bounds.height - inset)
        )
        let horizontalRoom = min(fitted.x - bounds.x, bounds.x + bounds.width - fitted.x)
        let verticalRoom = min(fitted.y - bounds.y, bounds.y + bounds.height - fitted.y)
        let axis: Axis = horizontalRoom >= verticalRoom ? .horizontal : .vertical
        let room = min(max(horizontalRoom, verticalRoom) - Self.edgeMargin, Self.maximumRadius)
        let outer = max(room, Self.minimumRadius)

        if scale > 1 {
            endRadius = outer
            startRadius = max(Self.minimumRadius, outer / scale)
        } else {
            startRadius = outer
            endRadius = max(Self.minimumRadius, outer * scale)
        }
        self.center = fitted
        self.axis = axis
        let duration = velocity > 0 ? abs(scale - 1) / velocity : Self.defaultDurationSeconds
        durationSeconds = Self.clamp(
            duration,
            lower: Self.durationRangeSeconds.lowerBound,
            upper: Self.durationRangeSeconds.upperBound
        )
    }

    /// End separation over start separation; differs from the requested scale only when clamped.
    public var effectiveScale: Double {
        endRadius / startRadius
    }

    /// The two finger positions at `radius` from the centre along ``axis``.
    public func fingers(atRadius radius: Double) -> (Point, Point) {
        switch axis {
        case .horizontal:
            (Point(x: center.x - radius, y: center.y), Point(x: center.x + radius, y: center.y))
        case .vertical:
            (Point(x: center.x, y: center.y - radius), Point(x: center.x, y: center.y + radius))
        }
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        guard lower <= upper else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }
}
