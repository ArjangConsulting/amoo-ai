import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import ProcessRunner
import XCTest

extension AndroidDriverTests {
    func testAutomaticInspectionUsesAndroidCLIHierarchy() async throws {
        let androidCLI = MockAndroidCLIRunner(elements: [
            .init(
                text: "Continue",
                resourceID: "continue",
                interactions: ["clickable"],
                bounds: "[10,20][110,70]",
                center: "[60,45]"
            )
        ])
        let companion = MockCompanionClient()
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .automatic,
            serial: "emulator-5554"
        )

        let hierarchy = try await driver.getViewHierarchy()
        let matches = try await driver.findElements(.init(id: "continue"))

        XCTAssertEqual(hierarchy.id, "android-cli-root")
        XCTAssertEqual(hierarchy.children.first?.frame, Rect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(matches.first?.label, "Continue")
        XCTAssertEqual(matches.first?.type, .button)
        let companionCalls = await companion.hierarchyCallCount()
        let androidCLICalls = await androidCLI.calls()
        XCTAssertEqual(companionCalls, 0)
        XCTAssertEqual(androidCLICalls.count, 2)
    }

    func testAndroidCLICenterBecomesTappableZeroSizeFrameWhenBoundsAreAbsent() async throws {
        let androidCLI = MockAndroidCLIRunner(elements: [
            .init(text: "Continue", resourceID: "continue", center: "[60,45]")
        ])
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            androidCLI: androidCLI,
            inspectionMode: .androidCLI
        )

        let matches = try await driver.findElements(.init(id: "continue"))

        XCTAssertEqual(matches.first?.frame, Rect(x: 60, y: 45, width: 0, height: 0))
        XCTAssertEqual(matches.first?.frame?.centre, Point(x: 60, y: 45))
    }

    func testAutomaticInspectionFallsBackToCompanion() async throws {
        let androidCLI = MockAndroidCLIRunner(
            error: ProcessRunnerError.nonZeroExit(command: "android layout", exitCode: 1, stderr: "unavailable")
        )
        let companion = MockCompanionClient()
        await companion.setHierarchy(ViewNode(id: "companion-root"))
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .automatic
        )

        let hierarchy = try await driver.getViewHierarchy()
        _ = try await driver.getViewHierarchy()

        XCTAssertEqual(hierarchy.id, "companion-root")
        let companionCalls = await companion.hierarchyCallCount()
        let androidCLICalls = await androidCLI.calls()
        XCTAssertEqual(companionCalls, 2)
        XCTAssertEqual(androidCLICalls.count, 1)
    }

    func testAutomaticInspectionKeepsSemanticSelectorsOnCompanion() async throws {
        let androidCLI = MockAndroidCLIRunner(elements: [.init(text: "Settings")])
        let companion = MockCompanionClient()
        await companion.setFindElementsResponses([[ElementInfo(id: "settings", label: "Settings")]])
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .automatic
        )

        let matches = try await driver.findElements(.init(description: "settings control"))

        XCTAssertEqual(matches.map(\.id), ["settings"])
        let androidCLICalls = await androidCLI.calls()
        XCTAssertTrue(androidCLICalls.isEmpty)
    }

    func testCompareInspectionReturnsCompanionAndRecordsOverlap() async throws {
        let androidCLI = MockAndroidCLIRunner(elements: [
            .init(text: "Continue", resourceID: "continue"),
            .init(text: "Cancel", resourceID: "cancel")
        ])
        let companion = MockCompanionClient()
        await companion.setHierarchy(ViewNode(
            id: "root",
            children: [ViewNode(id: "continue", label: "Continue")]
        ))
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .compare
        )

        let hierarchy = try await driver.getViewHierarchy()
        let comparison = await driver.latestInspectionComparison()

        XCTAssertEqual(hierarchy.id, "root")
        XCTAssertEqual(comparison?.companionElementCount, 2)
        XCTAssertEqual(comparison?.androidCLIElementCount, 3)
        XCTAssertEqual(comparison?.matchingIdentityCount, 1)
    }

    func testProductionInspectionModeReadsEnvironment() {
        XCTAssertEqual(AndroidInspectionMode.productionDefault(environment: [:]), .automatic)
        XCTAssertEqual(
            AndroidInspectionMode.productionDefault(environment: ["AMOO_ANDROID_INSPECTION_MODE": "compare"]),
            .compare
        )
    }

    func testAutomaticInspectionFallsBackWhenAndroidCLIReturnsEmptyLayout() async throws {
        // AndroidCLI succeeds but returns nothing because a companion instrumentation session
        // holds Android's single UI-automation-owner slot. The empty result must not be trusted.
        let androidCLI = MockAndroidCLIRunner(elements: [])
        let companion = MockCompanionClient()
        await companion.setHierarchy(ViewNode(
            id: "companion-root",
            children: [ViewNode(id: "most_loved", label: "Most Loved")]
        ))
        await companion.setFindElementsResponses([
            [ElementInfo(id: "most_loved", label: "Most Loved")]
        ])
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .automatic
        )

        let hierarchy = try await driver.getViewHierarchy()
        // Once the owner conflict is detected, the rest of the session skips AndroidCLI entirely.
        let matches = try await driver.findElements(.init(id: "most_loved"))

        XCTAssertEqual(hierarchy.id, "companion-root")
        XCTAssertEqual(matches.map(\.id), ["most_loved"])
        let androidCLICalls = await androidCLI.calls()
        XCTAssertEqual(androidCLICalls.count, 1)
    }

    func testAutomaticInspectionTrustsEmptyLayoutWhenCompanionAlsoSeesNothing() async throws {
        let androidCLI = MockAndroidCLIRunner(elements: [])
        let companion = MockCompanionClient()
        await companion.setHierarchy(ViewNode(id: "root"))
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .automatic
        )

        let first = try await driver.getViewHierarchy()
        _ = try await driver.getViewHierarchy()

        XCTAssertTrue(first.children.isEmpty)
        // A genuinely empty screen is not an owner conflict, so AndroidCLI stays in rotation.
        let androidCLICalls = await androidCLI.calls()
        XCTAssertEqual(androidCLICalls.count, 2)
    }
}
