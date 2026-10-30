@testable import CLI
import Foundation
import StudioProtocol
import XCTest

final class ConfigCommandTests: XCTestCase {
    private func write(_ json: String, in directory: URL) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(AmooProjectConfig.fileName))
    }

    func testValidConfigListsProfilesWithoutValues() throws {
        let scratch = try makeScratchDirectory()
        try write("""
        {"version": 1, "profiles": {"mock-user": {"apps": ["com.example.qa"],
          "fields": {"password": {"literal": "hunter2-canary", "class": "secret"}}}}}
        """, in: scratch.url)

        let result = handleConfigCommand(remaining: ["validate"], currentDirectory: scratch.url)

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("mock-user: apps com.example.qa; fields password"))
        XCTAssertFalse(result.output.contains("hunter2-canary"))
    }

    func testInvalidConfigFailsWithTheProblem() throws {
        let scratch = try makeScratchDirectory()
        try write(#"{"version": 1, "profiles": {"p": {"apps": [], "fields": {}}}}"#, in: scratch.url)

        let result = handleConfigCommand(remaining: ["validate", "--json"], currentDirectory: scratch.url)

        XCTAssertEqual(result.exitCode, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue((object["message"] as? String)?.contains("lists no apps") == true)
    }

    func testMissingConfigAndUsageErrors() throws {
        let scratch = try makeScratchDirectory()
        try FileManager.default.createDirectory(
            at: scratch.url.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        XCTAssertEqual(handleConfigCommand(remaining: ["validate"], currentDirectory: scratch.url).exitCode, 1)
        XCTAssertEqual(handleConfigCommand(remaining: [], currentDirectory: scratch.url).exitCode, 64)
        XCTAssertEqual(
            handleConfigCommand(remaining: ["validate", "--path"], currentDirectory: scratch.url).exitCode,
            64
        )
        XCTAssertEqual(handleConfigCommand(remaining: ["--help"], currentDirectory: scratch.url).exitCode, 0)
    }

    func testRuntimeLaunchEnvironmentNeverStoresSensitiveValues() {
        let masked = maskedLaunchEnvironment(["API_TOKEN": "t0ken", "FIREBASE_AUTH_EMULATOR_HOST": "10.0.2.2:9099"])
        XCTAssertEqual(masked["API_TOKEN"], "<redacted>")
        XCTAssertEqual(masked["FIREBASE_AUTH_EMULATOR_HOST"], "10.0.2.2:9099")
    }
}
