import AmooCore
import Foundation
@testable import MCPServer
import XCTest

/// An unfiltered `find_elements` reports elements that carry neither an identifier nor a label,
/// because a control no selector can name is still reachable by tapping its frame. These cover the
/// host half of that: what the selector carries down, and what a nameless element renders as.
final class UnlabeledElementTests: XCTestCase {
    func testUnfilteredQueryDoesNotRequestLabeledOnly() async {
        let driver = SelectorRecordingDriver()
        let executor = DriverToolExecutor(driver: driver)

        _ = await executor.execute(toolName: "find_elements", arguments: [:])

        let selector = await driver.lastSelector
        XCTAssertEqual(selector?.labeledOnly, false)
    }

    func testLabeledOnlyArgumentIsForwarded() async {
        let driver = SelectorRecordingDriver()
        let executor = DriverToolExecutor(driver: driver)

        _ = await executor.execute(toolName: "find_elements", arguments: ["labeled_only": "true"])

        let selector = await driver.lastSelector
        XCTAssertEqual(selector?.labeledOnly, true)
    }

    func testUnlabeledElementRendersAsItsTypeAndFrame() async {
        let driver = SelectorRecordingDriver(elements: [
            ElementInfo(id: "", label: "", type: .button, frame: Rect(x: 330, y: 100, width: 38, height: 38))
        ])
        let executor = DriverToolExecutor(driver: driver)

        let result = await executor.execute(toolName: "find_elements", arguments: [:])

        XCTAssertFalse(result.isError)
        // The centre, in points, is the entire usable answer for an element with no name.
        XCTAssertTrue(result.content.contains("[unlabeled]"), result.content)
        XCTAssertTrue(result.content.contains("(349,119)"), result.content)
    }

    func testNamedElementStillRendersItsIdentifierAndLabel() async {
        let driver = SelectorRecordingDriver(elements: [
            ElementInfo(id: "close", label: "Close", type: .button, frame: Rect(x: 0, y: 0, width: 40, height: 40))
        ])
        let executor = DriverToolExecutor(driver: driver)

        let result = await executor.execute(toolName: "find_elements", arguments: [:])

        XCTAssertTrue(result.content.contains("[close]"), result.content)
        XCTAssertTrue(result.content.contains("Close"), result.content)
        XCTAssertFalse(result.content.contains("[unlabeled]"), result.content)
    }
}

actor SelectorRecordingDriver: PlatformDriver {
    private let elements: [ElementInfo]
    private(set) var lastSelector: ElementSelector?

    init(elements: [ElementInfo] = []) {
        self.elements = elements
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        lastSelector = selector
        return elements
    }

    func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        try await findElements(selector)
    }
}
