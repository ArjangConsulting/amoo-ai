import AmooCore
@testable import AndroidDriver
import XCTest

final class AndroidOrientationTests: XCTestCase {
    func testLocksAutoRotateAndSetsTheSurfaceRotation() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)

        let reported = try await driver.setOrientation(.landscapeLeft)

        XCTAssertEqual(reported, .landscapeLeft)
        let autoRotate = await adb.systemSetting("accelerometer_rotation")
        let rotation = await adb.systemSetting("user_rotation")
        XCTAssertEqual(autoRotate, "0")
        XCTAssertEqual(rotation, "1")
    }

    /// Surface.ROTATION_90 is the device turned counter-clockwise — iOS's landscapeLeft.
    func testSurfaceRotationMatchesTheIOSNaming() {
        XCTAssertEqual(DeviceOrientation.portrait.surfaceRotation, 0)
        XCTAssertEqual(DeviceOrientation.landscapeLeft.surfaceRotation, 1)
        XCTAssertEqual(DeviceOrientation.portraitUpsideDown.surfaceRotation, 2)
        XCTAssertEqual(DeviceOrientation.landscapeRight.surfaceRotation, 3)
        for orientation in DeviceOrientation.allCases {
            XCTAssertEqual(DeviceOrientation(surfaceRotation: orientation.surfaceRotation), orientation)
        }
        XCTAssertNil(DeviceOrientation(surfaceRotation: 4))
    }

    func testEveryOrientationReadsBack() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)
        for orientation in DeviceOrientation.allCases {
            let reported = try await driver.setOrientation(orientation)
            XCTAssertEqual(reported, orientation)
        }
    }
}
