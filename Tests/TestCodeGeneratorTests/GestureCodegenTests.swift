import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

final class GestureCodegenTests: XCTestCase {
    private func makeTest(_ operations: [StudioToolOperation], platform: Platform) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Gestures",
            description: "",
            platform: platform,
            steps: [],
            compiledPlan: .init(compiler: "test", compilerVersion: "1", toolOperations: operations)
        )
    }

    private let drag = StudioToolOperation(
        id: "drag", tool: "drag", arguments: ["id": "card", "to_id": "done-column", "hold_ms": "600"]
    )
    private let pinchIn = StudioToolOperation(id: "pinch", tool: "pinch", arguments: ["id": "map", "scale": "2"])
    private let pinchOutApp = StudioToolOperation(
        id: "pinch-app", tool: "pinch", arguments: ["scale": "0.5", "velocity": "2"]
    )

    func testXCUITestDragsBetweenElementsAndPinchesWithASignedVelocity() throws {
        let source = try XCUITestEmitter().generate(makeTest([drag, pinchIn, pinchOutApp], platform: .ios)).source

        XCTAssertTrue(source.contains(
            ".press(forDuration: 0.6, thenDragTo: doneColumn"
        ), source)
        XCTAssertTrue(source.contains("withVelocity: .slow, thenHoldForDuration: 0.2)"), source)
        XCTAssertTrue(source.contains(".pinch(withScale: 2.0, velocity: 1.0)"), source)
        XCTAssertTrue(source.contains("app.pinch(withScale: 0.5, velocity: -2.0)"), source)
    }

    func testEspressoCarriesItsGestureHelpersOnlyWhenUsed() throws {
        let gestures = try EspressoEmitter().generate(makeTest([drag, pinchIn], platform: .android)).source
        XCTAssertTrue(gestures.contains(".perform(dragOnto("), gestures)
        XCTAssertTrue(gestures.contains(", 600L, 1000L))"), gestures)
        XCTAssertTrue(gestures.contains(".perform(pinch(2.0f, 1000L))"), gestures)
        XCTAssertTrue(gestures.contains("private fun injectTouch("), gestures)
        XCTAssertTrue(gestures.contains("import android.view.MotionEvent"), gestures)

        let tapOnly = StudioToolOperation(id: "tap", tool: "tap_element", arguments: ["id": "ok"])
        let plain = try EspressoEmitter().generate(makeTest([tapOnly], platform: .android)).source
        XCTAssertFalse(plain.contains("injectTouch"))
        XCTAssertFalse(plain.contains("import android.view.MotionEvent"))
    }

    func testComposeDragsToTheTargetCentreAndPinchesAboutTheNode() throws {
        let source = try ComposeEspressoEmitter()
            .generate(makeTest([drag, pinchIn, pinchOutApp], platform: .android)).source

        XCTAssertTrue(source.contains("onNode(hasTestTag(\"done-column\")).fetchSemanticsNode().boundsInRoot.center"))
        XCTAssertTrue(source.contains("advanceEventTime(600L)"), source)
        XCTAssertTrue(source.contains("val from = maxOf(minimum, outer / 2.0f)"), source)
        XCTAssertTrue(source.contains("composeTestRule.onRoot().performTouchInput {"), source)
        XCTAssertTrue(source.contains("val to = maxOf(minimum, outer * 0.5f)"), source)
        XCTAssertTrue(source.contains("import androidx.compose.ui.test.pinch"), source)
    }

    func testEmittersRefuseADragWithoutATargetAndAPinchWithoutAScale() {
        let noTarget = StudioToolOperation(id: "d", tool: "drag", arguments: ["id": "card"])
        let noScale = StudioToolOperation(id: "p", tool: "pinch", arguments: ["id": "map"])
        let flatScale = StudioToolOperation(id: "p", tool: "pinch", arguments: ["id": "map", "scale": "1"])
        for operation in [noTarget, noScale, flatScale] {
            XCTAssertThrowsError(try XCUITestEmitter().generate(makeTest([operation], platform: .ios)))
            XCTAssertThrowsError(try EspressoEmitter().generate(makeTest([operation], platform: .android)))
            XCTAssertThrowsError(try ComposeEspressoEmitter().generate(makeTest([operation], platform: .android)))
        }
    }
}
