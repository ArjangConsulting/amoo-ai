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
                        candidate("second", booted: booted),
                        candidate("first", booted: booted)
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

    func testDevicesSortNaturallyByNameThenOSVersionThenID() {
        let devices = [
            InitDeviceCandidate(id: "z", name: "iPhone 18 Pro", detail: "iOS 27.2", booted: true),
            InitDeviceCandidate(id: "a", name: "iPhone 18 Pro", detail: "iOS 27.2", booted: false),
            InitDeviceCandidate(id: "older", name: "iPhone 18 Pro", detail: "iOS 27.1", booted: false),
            InitDeviceCandidate(id: "ten", name: "Pixel 10", detail: "Android emulator", booted: true),
            InitDeviceCandidate(id: "nine", name: "Pixel 9", detail: "Android emulator", booted: false)
        ]
        XCTAssertEqual(sortedInitDevices(devices).map(\.id), ["older", "a", "z", "nine", "ten"])
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
