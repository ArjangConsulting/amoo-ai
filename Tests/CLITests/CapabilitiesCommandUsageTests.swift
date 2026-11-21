@testable import CLI
import XCTest

final class CapabilitiesCommandUsageTests: XCTestCase {
    func testHelpPrintsCapabilitiesUsage() {
        for arguments in [["--help"], ["-h"], ["--tool", "tap", "--help"]] {
            let result = runCapabilitiesCommand(arguments, store: .temporary())
            XCTAssertEqual(result.exitCode, 0, result.output)
            XCTAssertTrue(result.output.contains("Usage: amoo capabilities"), result.output)
            XCTAssertFalse(result.output.contains("Usage: amoo env"), result.output)
        }
    }

    func testUnknownFlagIsNamedWithoutEnvUsage() {
        for flag in ["--bogus", "--profile"] {
            let result = runCapabilitiesCommand([flag, "all"], store: .temporary())
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertTrue(result.output.contains("invalid_argument"), result.output)
            XCTAssertTrue(result.output.contains(flag), result.output)
            XCTAssertTrue(result.output.contains("--runtime-id"), result.output)
            XCTAssertFalse(result.output.contains("Usage: amoo env"), result.output)
        }
    }

    func testOtherFlagReaderCommandsDoNotPrintEnvUsage() async {
        for args in [["usage", "report", "--bogus"], ["agent", "validate-report", "--bogus"]] {
            let result = await CLIApp().run(args: args)
            XCTAssertNotEqual(result.exitCode, 0, "\(args): \(result.output)")
            XCTAssertFalse(result.output.contains("Usage: amoo env"), "\(args): \(result.output)")
        }
    }

    func testEnvUsageErrorsStillShowEnvUsage() async {
        let result = await CLIApp().run(args: ["env", "up", "--platform", "ios", "--bogus"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("Unexpected argument(s): --bogus."), result.output)
        XCTAssertTrue(result.output.contains("Usage: amoo env"), result.output)
    }
}
