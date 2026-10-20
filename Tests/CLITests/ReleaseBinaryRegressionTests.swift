import Foundation
import XCTest

final class ReleaseBinaryRegressionTests: XCTestCase {
    func testInspectionCommandsFailNormallyWithoutCompanion() throws {
        guard let binary = ProcessInfo.processInfo.environment["AMOO_RELEASE_REGRESSION_BINARY"] else {
            throw XCTSkip("Set AMOO_RELEASE_REGRESSION_BINARY to check an installed/release binary.")
        }
        let scratch = try makeScratchDirectory()
        for tool in ["current_app", "describe_screen"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [
                "device",
                "--platform",
                "ios",
                "--device",
                "amoo-regression-nonexistent-device",
                "--port",
                "1",
                tool
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["AMOO_RUNTIME_DIR"] = scratch.url.path
            environment.removeValue(forKey: "AMOO_RUNTIME_ID")
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(bytes: data, encoding: .utf8) ?? ""
            XCTAssertEqual(process.terminationReason, .exit, "\(tool): \(text)")
            XCTAssertEqual(process.terminationStatus, 1, "\(tool): \(text)")
            XCTAssertFalse(text.contains("freed pointer"), text)
        }
    }

    /// Run against the distributed executable, not a test-linked copy of CLIApp:
    /// AMOO_RELEASE_REGRESSION_BINARY=/absolute/path/amoo swift test --filter ReleaseBinaryRegressionTests
    func testVersionDoesNotAbortWithoutACompanion() throws {
        guard let binary = ProcessInfo.processInfo.environment["AMOO_RELEASE_REGRESSION_BINARY"] else {
            throw XCTSkip("Set AMOO_RELEASE_REGRESSION_BINARY to check an installed/release binary.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationReason, .exit, text)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.hasPrefix("amoo "), text)
    }
}
