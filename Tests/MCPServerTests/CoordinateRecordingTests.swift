// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
@testable import MCPServer
import TestSession
import XCTest

final class CoordinateRecordingTests: XCTestCase {
    func testPointPixelAndNormalizedSwipesBindTheSameRow() async throws {
        let executor = DriverToolExecutor(driver: GeometryOnlyDriver())
        for (unit, fromX, fromY, toX, toY) in [
            ("points", "10", "20", "30", "20"),
            ("pixels", "30", "60", "90", "60"),
            ("normalized", "0.1", "0.1", "0.3", "0.1")
        ] {
            let arguments = try await executor.normalizedCoordinates(tool: "swipe", arguments: [
                "unit": unit, "from_x": fromX, "from_y": fromY, "to_x": toX, "to_y": toY
            ])
            let session = TestSession(
                id: unit, appID: "app", deviceID: "device", platform: .ios,
                driver: GeometryOnlyDriver(), cleanup: {}
            )
            await session.record(SessionAction(
                timestamp: Date(), toolName: "find_elements", arguments: [:], result: "row", isError: false,
                observedElements: [RecordedElement(
                    id: "row", label: "Row", frame: RecordedRect(x: 0, y: 0, width: 50, height: 50), hitPoint: nil
                )]
            ))
            await session.record(SessionAction(
                timestamp: Date(), toolName: "swipe", arguments: arguments, result: "swiped", isError: false
            ))
            let actions = await session.actions
            XCTAssertEqual(actions.last?.gestureTarget?.elementID, "row", unit)
            XCTAssertEqual(arguments["from_x"].flatMap(Double.init), 10)
            XCTAssertEqual(arguments["from_y"].flatMap(Double.init), 20)
        }
    }

    /// `swipe_in_direction` with a start point aims at a cell that has no usable id; it runs and
    /// records as the equivalent coordinate `swipe`, so the recorder still binds it to the row.
    func testDirectionalSwipeFromPointBecomesCoordinateSwipe() async throws {
        let executor = DriverToolExecutor(driver: GeometryOnlyDriver())
        let (tool, arguments) = try await executor.canonicalGesture(tool: "swipe_in_direction", arguments: [
            "direction": "left", "from_x": "60", "from_y": "120", "unit": "pixels", "distance": "15"
        ])
        XCTAssertEqual(tool, "swipe")
        XCTAssertEqual(arguments["from_x"].flatMap(Double.init), 20)
        XCTAssertEqual(arguments["from_y"].flatMap(Double.init), 40)
        XCTAssertEqual(arguments["to_x"].flatMap(Double.init), 5)
        XCTAssertEqual(arguments["to_y"].flatMap(Double.init), 40)
        XCTAssertEqual(arguments["unit"], "points")
        XCTAssertNil(arguments["direction"])

        let session = TestSession(
            id: "s", appID: "app", deviceID: "device", platform: .ios, driver: GeometryOnlyDriver(), cleanup: {}
        )
        await session.record(SessionAction(
            timestamp: Date(), toolName: "find_elements", arguments: [:], result: "row", isError: false,
            observedElements: [RecordedElement(
                id: "row", label: "Row", frame: RecordedRect(x: 0, y: 0, width: 100, height: 50), hitPoint: nil
            )]
        ))
        await session.record(SessionAction(
            timestamp: Date(), toolName: tool, arguments: arguments, result: "swiped", isError: false
        ))
        let actions = await session.actions
        XCTAssertEqual(actions.last?.gestureTarget?.elementID, "row")
    }

    func testDirectionalSwipeFromPointRejectsAmbiguousTargets() async throws {
        let executor = DriverToolExecutor(driver: GeometryOnlyDriver())
        for arguments in [
            ["direction": "left", "from_x": "10"],
            ["direction": "left", "from_x": "10", "from_y": "10", "element_id": "row"],
            ["direction": "sideways", "from_x": "10", "from_y": "10"]
        ] {
            do {
                _ = try await executor.canonicalGesture(tool: "swipe_in_direction", arguments: arguments)
                XCTFail("expected rejection for \(arguments)")
            } catch let error as ToolExecutionError {
                XCTAssertEqual(error.code, "invalid_argument")
            }
        }
        let (tool, untouched) = try await executor.canonicalGesture(
            tool: "swipe_in_direction", arguments: ["direction": "up", "element_id": "row"]
        )
        XCTAssertEqual(tool, "swipe_in_direction")
        XCTAssertEqual(untouched, ["direction": "up", "element_id": "row"])
    }
}

private actor GeometryOnlyDriver: PlatformDriver {
    func screenGeometry() async throws -> ScreenSize {
        ScreenSize(widthPoints: 100, heightPoints: 200, widthPixels: 300, heightPixels: 600, scale: 3)
    }
}

// swiftlint:enable multiline_arguments
