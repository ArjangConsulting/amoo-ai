import AmooCore
@testable import AndroidDriver
import XCTest

final class AndroidElementGeometryTests: XCTestCase {
    func testResizableActiveDensityWinsOverStalePhysicalDensity() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(
            ["shell", "dumpsys", "display"],
            outputs: ["mOverrideDisplayInfo=DisplayInfo{displayId 0, real 1920 x 1200, density 240}"]
        )
        await adb.stubRawCommand(["shell", "wm", "density"], outputs: ["Physical density: 420"])
        let geometry = try await AndroidDriver(companion: MockCompanionClient(), adb: adb).elementGeometry()
        XCTAssertEqual(geometry?.framesPerUnit, 1.5)
    }

    func testOverrideDensityWinsOverPhysicalDensity() {
        XCTAssertEqual(AndroidDriver.effectiveDensity("Physical density: 420\nOverride density: 480\n"), 480)
        XCTAssertEqual(AndroidDriver.effectiveDensity("Physical density: 420\n"), 420)
    }

    func testUnparseableDensityIsUnknown() {
        XCTAssertNil(AndroidDriver.effectiveDensity(""))
        XCTAssertNil(AndroidDriver.effectiveDensity("Physical density: 0"))
        XCTAssertNil(AndroidDriver.effectiveDensity("wm: command not found"))
    }

    func testUnknownDensityLeavesGeometryUnknown() async throws {
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: MockADBRunner())
        let geometry = try await driver.elementGeometry()
        XCTAssertNil(geometry)
    }

    func testDensityNormalizesPixelsToDp() {
        let geometry = ElementGeometry(unit: "dp", framesPerUnit: 420.0 / 160)
        let frame = geometry.normalized(Rect(x: 0, y: 105, width: 126, height: 63))
        XCTAssertEqual(frame.y, 40, accuracy: 1e-9)
        XCTAssertEqual(frame.width, 48, accuracy: 1e-9)
        XCTAssertEqual(frame.height, 24, accuracy: 1e-9)
    }
}
