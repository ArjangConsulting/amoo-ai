import AmooCore
@testable import CLI
import SwiftyTerminal
import XCTest

final class InitDeviceSelectionTests: InitTestCase {
    func testDeviceSelectionStartsEmptyAndRequiresACheckedDevice() async throws {
        for platform in [Platform.ios, .android] {
            for booted in [false, true] {
                let prompter = ScriptedPrompter()
                prompter.multi = [[1]]
                var request = InitRequest()
                request.platform = platform
                let completed = try await completeInitRequest(
                    request,
                    discovery: discovery(devices: [
                        candidate("first", booted: booted),
                        candidate("second", booted: booted)
                    ]),
                    prompter: prompter
                )
                XCTAssertEqual(completed.devices, ["second"])
                XCTAssertEqual(prompter.multiDefaults, [[]])

                var menu = try SelectionMenu(
                    title: "Select devices to prepare for testing",
                    options: ["First", "Second"],
                    allowsMultiple: true,
                    defaults: XCTUnwrap(prompter.multiDefaults.first)
                )
                XCTAssertTrue(menu.selected.isEmpty)
                XCTAssertNil(menu.handle(.enter))
                XCTAssertNil(menu.handle(.down))
                XCTAssertNil(menu.handle(.enter))
                XCTAssertNil(menu.handle(.character(" ")))
                XCTAssertNil(menu.handle(.character(" ")))
                XCTAssertNil(menu.handle(.enter))
                XCTAssertNil(menu.handle(.character(" ")))
                XCTAssertEqual(menu.handle(.enter), .submitted([1]))
            }
        }
    }

    func testCancellingDeviceSelectionDoesNotAdvanceOrPrepareDevices() async {
        for platform in [Platform.ios, .android] {
            let prompter = ScriptedPrompter()
            prompter.multi = [nil]
            let result = await runInitCommand(
                ["--platform", platform.rawValue, "--no-skills"],
                runtime: runtime(
                    prompter: prompter,
                    interactive: true,
                    discovery: discovery(devices: [candidate("phone")]),
                    setup: forbidden("cancelling device selection must not prepare devices")
                )
            )
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertTrue(result.output.hasPrefix("Cancelled"))
            XCTAssertEqual(prompter.multiDefaults, [[]])
            XCTAssertFalse(prompter.transcript.joined().contains("Save device connection details"))
        }
    }
}
