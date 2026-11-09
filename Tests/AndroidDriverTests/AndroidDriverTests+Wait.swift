import AmooCore
import AndroidDriver
import XCTest

extension AndroidDriverTests {
    func testWaitForElementToDisappearWaitsOnTheDeviceWhenTheCompanionCan() async throws {
        let companion = MockCompanionClient()
        await companion.setWaitsForAbsenceOnDevice(true)
        await companion.setFindElementsResponses([[ElementInfo(id: "spinner", label: "Loading")]])
        let driver = AndroidDriver(companion: companion, adb: MockADBRunner())

        try await driver.waitForElementToDisappear(.init(id: "spinner"), timeout: Duration(milliseconds: 1))

        let calls = await companion.waitForElementCalls()
        XCTAssertEqual(calls.map(\.selector.id), ["spinner"])
    }
}
