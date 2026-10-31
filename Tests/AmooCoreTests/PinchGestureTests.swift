@testable import AmooCore
import XCTest

final class PinchGestureTests: XCTestCase {
    private let phone = Rect(x: 0, y: 0, width: 400, height: 800)

    func testZoomInSpreadsFingersByTheRequestedScale() throws {
        let pinch = try PinchGesture(center: Point(x: 200, y: 400), scale: 2, velocity: 0, bounds: phone)

        XCTAssertEqual(pinch.center, Point(x: 200, y: 400))
        XCTAssertEqual(pinch.axis, .vertical)
        XCTAssertGreaterThan(pinch.endRadius, pinch.startRadius)
        XCTAssertEqual(pinch.effectiveScale, 2, accuracy: 0.0001)
        XCTAssertEqual(pinch.durationSeconds, PinchGesture.defaultDurationSeconds)
    }

    func testZoomOutBringsFingersTogether() throws {
        let pinch = try PinchGesture(center: Point(x: 200, y: 400), scale: 0.5, velocity: 0, bounds: phone)

        XCTAssertLessThan(pinch.endRadius, pinch.startRadius)
        XCTAssertEqual(pinch.effectiveScale, 0.5, accuracy: 0.0001)
    }

    func testFingersStayInsideBoundsNearAnEdge() throws {
        let pinch = try PinchGesture(center: Point(x: 5, y: 790), scale: 3, velocity: 0, bounds: phone)

        for radius in [pinch.startRadius, pinch.endRadius] {
            let (first, second) = pinch.fingers(atRadius: radius)
            for finger in [first, second] {
                XCTAssertGreaterThanOrEqual(finger.x, phone.x)
                XCTAssertLessThanOrEqual(finger.x, phone.x + phone.width)
                XCTAssertGreaterThanOrEqual(finger.y, phone.y)
                XCTAssertLessThanOrEqual(finger.y, phone.y + phone.height)
            }
        }
    }

    func testExtremeScaleIsClampedToTheMinimumFingerSeparation() throws {
        let pinch = try PinchGesture(center: Point(x: 200, y: 400), scale: 0.001, velocity: 0, bounds: phone)

        XCTAssertEqual(pinch.endRadius, PinchGesture.minimumRadius)
        XCTAssertGreaterThan(pinch.effectiveScale, 0.001)
    }

    func testVelocitySetsDurationWithinTheAllowedRange() throws {
        let measured = try PinchGesture(center: Point(x: 200, y: 400), scale: 2, velocity: 2, bounds: phone)
        XCTAssertEqual(measured.durationSeconds, 0.5, accuracy: 0.0001)

        let tooFast = try PinchGesture(center: Point(x: 200, y: 400), scale: 2, velocity: 1000, bounds: phone)
        XCTAssertEqual(tooFast.durationSeconds, PinchGesture.durationRangeSeconds.lowerBound)
    }

    func testRejectsScalesThatAreNotAPinch() {
        for scale in [0, -1, 1, .nan, .infinity] {
            XCTAssertThrowsError(
                try PinchGesture(center: Point(x: 200, y: 400), scale: scale, velocity: 0, bounds: phone),
                "scale \(scale)"
            ) { error in
                XCTAssertTrue(error is PinchGesture.InvalidScale)
            }
        }
    }

    func testRadiusIsCappedOnLargeScreens() throws {
        let tablet = Rect(x: 0, y: 0, width: 1366, height: 1024)
        let pinch = try PinchGesture(center: Point(x: 683, y: 512), scale: 2, velocity: 0, bounds: tablet)

        XCTAssertEqual(pinch.axis, .horizontal)
        XCTAssertEqual(pinch.endRadius, PinchGesture.maximumRadius)
    }
}
