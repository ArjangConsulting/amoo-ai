@testable import CLI
import XCTest

final class DeviceArgumentValidationTests: XCTestCase {
    /// `query=` is not a `find_elements` argument; it used to be dropped silently, returning every
    /// element on screen as though the filter had matched them all.
    func testUnknownKeyIsRejectedWithTheAcceptedOnes() throws {
        let message = try XCTUnwrap(unknownArgumentMessage(tool: "find_elements", arguments: ["query": "Today"]))
        XCTAssertTrue(message.contains("Unknown argument for find_elements: query."), message)
        XCTAssertTrue(message.contains("label"), message)
        XCTAssertFalse(message.contains("session_id"), message)
    }

    func testDeclaredKeysPass() {
        XCTAssertNil(unknownArgumentMessage(tool: "find_elements", arguments: ["label": "Today", "limit": "5"]))
        XCTAssertNil(unknownArgumentMessage(tool: "device_launch_app", arguments: ["app_id": "com.example.app"]))
    }

    func testArgumentlessToolSaysSo() throws {
        let message = try XCTUnwrap(unknownArgumentMessage(tool: "press_home", arguments: ["force": "true"]))
        XCTAssertTrue(message.hasSuffix("It takes no arguments."), message)
    }

    func testUnknownToolIsLeftToTheExecutor() {
        XCTAssertNil(unknownArgumentMessage(tool: "no_such_tool", arguments: ["x": "1"]))
    }

    /// Validation runs before any companion lookup or connection, so it answers instantly.
    func testRunDeviceCommandRejectsBeforeConnecting() async {
        let options = DeviceCommandOptions(
            platform: .ios, port: 1, deviceID: nil, tool: "find_elements", arguments: ["query": "x"]
        )
        let result = await runDeviceCommand(options: options) { _ in
            XCTFail("companion ownership must not be probed for an invalid call")
            return nil
        }
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.hasPrefix("Unknown argument"), result.output)
    }
}
