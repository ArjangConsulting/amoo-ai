import AmooCore
@testable import MCPServer
import XCTest

final class GestureToolTests: XCTestCase {
    private func makeDriver() async -> MockDriver {
        let driver = MockDriver()
        await driver.setElementFrames([
            "card": Rect(x: 0, y: 100, width: 100, height: 50),
            "done-column": Rect(x: 200, y: 400, width: 100, height: 200),
            "map": Rect(x: 0, y: 0, width: 400, height: 600)
        ])
        await driver.setScreenSize(
            ScreenSize(widthPoints: 400, heightPoints: 800, widthPixels: 1200, heightPixels: 2400, scale: 3)
        )
        return driver
    }

    func testDragResolvesBothElementsToTheirCentres() async {
        let driver = await makeDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "drag",
            arguments: ["id": "card", "to_id": "done-column", "check_hittable": "false"]
        )

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("onto 'label' at (250, 500)"), result.content)
        let calls = await driver.calls
        XCTAssertEqual(calls, ["drag:50.0,125.0->250.0,500.0:800:1000"])
    }

    func testDragAcceptsCoordinatesAndExplicitTiming() async {
        let driver = await makeDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "drag",
            arguments: [
                "from_x": "10", "from_y": "20", "to_x": "30", "to_y": "40", "hold_ms": "0", "duration_ms": "250"
            ]
        )

        XCTAssertFalse(result.isError, result.content)
        let calls = await driver.calls
        XCTAssertEqual(calls, ["drag:10.0,20.0->30.0,40.0:0:250"])
    }

    func testDragRejectsAmbiguousOrMissingEnds() async {
        let driver = await makeDriver()
        let executor = DriverToolExecutor(driver: driver)

        let both = await executor.execute(
            toolName: "drag", arguments: ["id": "card", "from_x": "1", "from_y": "2", "to_id": "done-column"]
        )
        let noTarget = await executor.execute(toolName: "drag", arguments: ["id": "card"])
        let badHold = await executor.execute(
            toolName: "drag", arguments: ["id": "card", "to_id": "done-column", "hold_ms": "-5"]
        )

        XCTAssertTrue(both.isError)
        XCTAssertTrue(both.content.contains("not both"), both.content)
        XCTAssertTrue(noTarget.isError)
        XCTAssertTrue(noTarget.content.contains("to_id"), noTarget.content)
        XCTAssertTrue(badHold.isError)
        let calls = await driver.calls
        XCTAssertTrue(calls.isEmpty, "\(calls)")
    }

    func testPinchOnAnElementZoomsInAroundItsCentre() async {
        let driver = await makeDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "pinch", arguments: ["id": "map", "scale": "2.5", "velocity": "3"]
        )

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("zoom in"), result.content)
        let calls = await driver.calls
        XCTAssertEqual(calls, ["pinch:200.0,300.0:2.5:3.0:0.0,0.0,400.0x600.0"])
    }

    func testPinchWithNoTargetUsesTheScreenCentre() async {
        let driver = await makeDriver()
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "pinch", arguments: ["scale": "0.5"])

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("zoom out"), result.content)
        let calls = await driver.calls
        XCTAssertEqual(calls, ["pinch:200.0,400.0:0.5:0.0"])
    }

    func testPinchRejectsScalesThatAreNotAPinch() async {
        let driver = await makeDriver()
        let executor = DriverToolExecutor(driver: driver)
        for scale in ["1", "0", "-2", "big"] {
            let result = await executor.execute(toolName: "pinch", arguments: ["scale": scale])
            XCTAssertTrue(result.isError, "scale \(scale) should be rejected")
        }
        let missing = await executor.execute(toolName: "pinch", arguments: [:])
        XCTAssertTrue(missing.isError)
        let calls = await driver.calls
        XCTAssertTrue(calls.isEmpty, "\(calls)")
    }
}
