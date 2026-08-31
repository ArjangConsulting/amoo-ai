import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import ProcessRunner
import XCTest

extension AndroidDriverTests {
    func testAutomaticInspectionKeepsCompanionAuthoritativeWhenCLIIsNonEmpty() async throws {
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
        await companion.setHierarchy(ViewNode(
            id: "companion-root",
            children: [ViewNode(id: "continue", label: "Continue", type: .button)]
        ))
        await companion.setFindElementsResponses([[ElementInfo(id: "continue", label: "Continue", type: .button)]])
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .automatic,
            serial: "emulator-5554"
        )

        let hierarchy = try await driver.getViewHierarchy()
        let matches = try await driver.findElements(.init(id: "continue"))

        XCTAssertEqual(hierarchy.id, "companion-root")
        XCTAssertEqual(matches.first?.label, "Continue")
        XCTAssertEqual(matches.first?.type, .button)
        let companionCalls = await companion.hierarchyCallCount()
        let androidCLICalls = await androidCLI.calls()
        XCTAssertEqual(companionCalls, 1)
        XCTAssertTrue(androidCLICalls.isEmpty)
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

    func testAutomaticInspectionFallsBackToAndroidCLIWhenCompanionFails() async throws {
        let androidCLI = MockAndroidCLIRunner(elements: [
            .init(text: "Continue", resourceID: "continue", interactions: ["clickable"])
        ])
        let companion = MockCompanionClient()
        await companion.setInspectionError(
            ProcessRunnerError.nonZeroExit(command: "companion", exitCode: 1, stderr: "unavailable")
        )
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .automatic
        )

        let hierarchy = try await driver.getViewHierarchy()
        let matches = try await driver.findElements(.init(id: "continue"))

        XCTAssertEqual(hierarchy.id, "android-cli-root")
        XCTAssertEqual(matches.map(\.id), ["continue"])
        let androidCLICalls = await androidCLI.calls()
        XCTAssertEqual(androidCLICalls.count, 2)
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
        XCTAssertEqual(comparison?.companionOnlyIdentityCount, 1) // companion root
        XCTAssertEqual(comparison?.androidCLIOnlyIdentityCount, 2) // CLI root + Cancel
    }

    func testProductionInspectionModeReadsEnvironment() {
        XCTAssertEqual(AndroidInspectionMode.productionDefault(environment: [:]), .companion)
        XCTAssertEqual(
            AndroidInspectionMode.productionDefault(environment: ["AMOO_ANDROID_INSPECTION_MODE": "compare"]),
            .compare
        )
    }

    func testAutomaticInspectionDoesNotTrustTruncatedNonEmptyAndroidCLIResult() async throws {
        let androidCLI = MockAndroidCLIRunner(elements: [
            .init(text: "Only CLI Element", resourceID: "only-cli")
        ])
        let companion = MockCompanionClient()
        await companion.setHierarchy(ViewNode(
            id: "companion-root",
            children: [
                ViewNode(id: "first", label: "First"),
                ViewNode(id: "second", label: "Second")
            ]
        ))
        let driver = AndroidDriver(
            companion: companion,
            androidCLI: androidCLI,
            inspectionMode: .automatic
        )

        let hierarchy = try await driver.getViewHierarchy()

        XCTAssertEqual(hierarchy.id, "companion-root")
        let androidCLICalls = await androidCLI.calls()
        XCTAssertTrue(androidCLICalls.isEmpty)
    }
}
