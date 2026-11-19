// swiftlint:disable multiline_arguments
import AmooCore
import MCP
@testable import MCPServer
import XCTest

/// A SwiftUI `.overlay` floating button can come before the list it floats over in the
/// accessibility tree, so the frame check read a subtitle row as covering it and refused every tap.
/// A suspected block is now put to the device's hit test before the tap is refused.
final class TapHitTestTests: XCTestCase {
    private static let window = Rect(x: 0, y: 0, width: 390, height: 844)
    private static let fab = ElementInfo(
        id: "options_button", label: "Playback options", type: .button, frame: Rect(
            x: 16,
            y: 760,
            width: 56,
            height: 56
        )
    )

    /// The floating button first, then the list whose row spans the button's tap point.
    private static let overlayScreen = ViewNode(
        id: "root", type: .other, frame: window,
        children: [
            ViewNode(id: fab.id, label: fab.label, type: .button, frame: fab.frame),
            ViewNode(
                id: "subtitles", type: .scrollView, frame: Rect(x: 0, y: 100, width: 390, height: 744),
                children: [
                    ViewNode(
                        id: "", label: "Subtitle at 00:05. Tap to seek to this time.", type: .button,
                        frame: Rect(x: 0, y: 770, width: 390, height: 44)
                    )
                ]
            )
        ]
    )

    private func tap(
        _ verdict: HitTestVerdict,
        arguments: [String: String] = [:]
    ) async -> (ToolResult, TapCheckDriver) {
        let driver = TapCheckDriver(target: Self.fab, hierarchy: Self.overlayScreen, hitTestVerdict: verdict)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": Self.fab.id].merging(arguments) { _, new in new }
        )
        return (result, driver)
    }

    func testDeviceHitTestOverrulesAFrameOverlapAndTaps() async {
        let (result, driver) = await tap(.hittable)
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["hit_test"], .string("hittable"))
        XCTAssertEqual(result.structuredContent?.objectValue?["hittability_checked"], .bool(true))
        XCTAssertTrue(result.content.contains("device hit test found the element on top"), result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps.count, 1)
    }

    func testRequiredCheckIsAlsoSatisfiedByTheHitTest() async {
        let (result, _) = await tap(.hittable, arguments: ["check_hittable": "true"])
        XCTAssertFalse(result.isError, result.content)
    }

    func testConfirmedBlockIsReportedAsFact() async {
        let (result, driver) = await tap(.notHittable)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("would not receive the tap"), result.content)
        XCTAssertTrue(result.content.contains("confirmed by the device hit test"), result.content)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testUnconfirmedBlockIsReportedAsPossibleAndNamesTheOverlayCase() async {
        let (result, driver) = await tap(.unsupported)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("may not receive the tap"), result.content)
        XCTAssertTrue(result.content.contains("Subtitle at 00:05"), result.content)
        XCTAssertTrue(result.content.contains("cannot see paint order"), result.content)
        XCTAssertTrue(result.content.contains("no device hit test was available"), result.content)
        XCTAssertTrue(result.content.contains("check_hittable=false"), result.content)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testUnresolvedHitTestSaysSo() async {
        let (result, _) = await tap(.unresolved)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("could not resolve the element"), result.content)
    }

    /// An ordinary tap pays nothing: the hit test runs only when the frame check found a block.
    func testUnblockedTapNeverAsksForAHitTest() async {
        let screen = ViewNode(
            id: "root", type: .other, frame: Self.window,
            children: [ViewNode(id: Self.fab.id, label: Self.fab.label, type: .button, frame: Self.fab.frame)]
        )
        let driver = TapCheckDriver(target: Self.fab, hierarchy: screen, hitTestVerdict: .notHittable)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": Self.fab.id]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertNil(result.structuredContent?.objectValue?["hit_test"])
        let hitTests = await driver.hitTests
        XCTAssertEqual(hitTests, 0)
    }

    /// An off-screen point is plain geometry, not tree order, so it is refused without asking.
    func testOffScreenPointIsRefusedWithoutAHitTest() async {
        var offScreen = Self.fab
        offScreen.frame = Rect(x: 500, y: 760, width: 56, height: 56)
        let screen = ViewNode(
            id: "root", type: .other, frame: Self.window,
            children: [ViewNode(id: offScreen.id, label: offScreen.label, type: .button, frame: offScreen.frame)]
        )
        let driver = TapCheckDriver(target: offScreen, hierarchy: screen, hitTestVerdict: .hittable)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": offScreen.id]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("outside the visible screen"), result.content)
        let hitTests = await driver.hitTests
        XCTAssertEqual(hitTests, 0)
    }
}

// swiftlint:enable multiline_arguments
