@testable import CLI
import Foundation
import XCTest

/// A flow's `device_pull_app_file` writes into the run's output directory unless told otherwise.
final class FlowAppFileTests: XCTestCase {
    private func output(
        _ given: String?,
        tool: String = "device_pull_app_file",
        directory: URL? = URL(fileURLWithPath: "/runs/r1")
    ) -> String? {
        var arguments = ["app_id": "com.example.app", "path": "files/net/session.har"]
        arguments["output"] = given
        return flowOutputArguments(arguments, tool: tool, outputDirectory: directory)["output"]
    }

    func testOutputDefaultsToTheRunsOutputDirectory() {
        XCTAssertEqual(output(nil), "/runs/r1/session.har")
        XCTAssertEqual(output("har/a.har"), "/runs/r1/har/a.har")
        XCTAssertEqual(output("/elsewhere/a.har"), "/elsewhere/a.har")
        XCTAssertNil(output(nil, directory: nil))
        XCTAssertNil(output(nil, tool: "take_screenshot"))
    }
}
