import AmooCore
@testable import CLI
import Foundation
import MCPServer
import XCTest

final class StructuredVerificationTests: XCTestCase {
    func testMultiwordSelectorsRoundTripThroughJSONFileAndLegacyArguments() throws {
        let directory = try makeScratchDirectory()
        let file = directory.url.appending(path: "arguments.json")
        try Data(#"{"label":"Account settings","limit":2,"response_mode":"compact"}"#.utf8).write(to: file)
        let options = try parseDeviceCommandOptions(args: [
            "--runtime-id", "runtime-owned", "--json", "find_elements", "--arguments-json", "@" + file.path
        ]).get()
        XCTAssertEqual(options.arguments["label"], "Account settings")
        XCTAssertEqual(options.arguments["limit"], "2")
        XCTAssertEqual(options.runtimeID, "runtime-owned")
        XCTAssertNil(MCPServer.validateArguments(tool: options.tool, arguments: options.arguments))
        let legacy = try parseDeviceCommandOptions(args: ["find_elements", "label=Account settings"]).get()
        XCTAssertEqual(legacy.arguments["label"], "Account settings")
    }

    func testMalformedSplitSelectorNamesArgumentAndShowsValidExample() throws {
        do {
            _ = try parseDeviceCommandOptions(args: ["find_elements", "label=Account", "settings"]).get()
            XCTFail("Expected validation failure")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("settings"))
            XCTAssertTrue(message.contains("'label=Account settings'"))
            XCTAssertTrue(message.contains("--arguments-json"))
        }
    }

    func testInvalidStructuredArgumentCannotReachDevice() async throws {
        let options = try parseDeviceCommandOptions(args: [
            "--json", "tap", "--arguments-json", #"{"x":"not a number","y":2}"#
        ]).get()
        let result = await runDeviceCommand(options: options) { _ in
            XCTFail("Validation must precede companion lookup")
            return nil
        }
        XCTAssertEqual(result.exitCode, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let fields = try XCTUnwrap(object["structured"] as? [String: Any])
        XCTAssertEqual(fields["argument"] as? String, "x")
        XCTAssertNotNil(fields["example"])
        XCTAssertEqual(fields["dispatch_status"] as? String, "not_dispatched")
    }

    func testCapabilityDiscoveryPublishesRuntimeIdentityAndCanonicalFlag() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let runtime = try store.start(platform: .ios, deviceID: "SIM")
        let result = runCapabilitiesCommand(["--runtime-id", runtime.id], store: store)
        XCTAssertEqual(result.exitCode, 0, result.output)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual((object["runtime"] as? [String: Any])?["runtime_id"] as? String, runtime.id)
        XCTAssertEqual((object["invocation"] as? [String: Any])?["runtime_flag"] as? String, "--runtime-id")
        XCTAssertThrowsError(try parseDeviceCommandOptions(args: ["--lease", runtime.id, "current_app"]).get())
    }
}
