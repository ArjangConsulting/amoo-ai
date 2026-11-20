import AmooTools
@testable import CLI
import XCTest

/// `amoo device start_session` started nothing a later call could use, and the reply still pointed
/// at `amoo mcp serve`. Session and warm-companion tools are hidden from the CLI catalog and refused
/// with the CLI path instead.
final class LongLivedToolTests: XCTestCase {
    func testDeviceRefusesALongLivedToolWithTheCLIPath() async {
        let options = DeviceCommandOptions(
            platform: .ios,
            port: 22087,
            deviceID: "SIM",
            tool: "start_session",
            arguments: ["app_id": "com.example"],
            json: true
        )
        let result = await runDeviceCommand(options: options)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("amoo env up"), result.output)
        XCTAssertFalse(result.output.contains("mcp serve"), result.output)
    }

    func testTheCLICatalogOmitsLongLivedTools() async {
        let names = Set(ToolCatalog().cliToolDefinitions().map(\.name))
        XCTAssertTrue(names.isDisjoint(with: ToolCatalog.longLivedOnlyTools))
        XCTAssertTrue(names.contains("get_run_telemetry"), "works from one call; stays listed")
        let tools = await CLIApp().run(args: ["--tools"]).output
        XCTAssertFalse(tools.contains("start_session"), tools)
    }

    func testAFlowUsageErrorShowsTheFlowHelp() async {
        let result = await CLIApp().run(args: ["flow", "x.amoo.json", "--json"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("Unexpected argument(s): --json."), result.output)
        XCTAssertTrue(result.output.contains("Usage: amoo flow"), result.output)
        XCTAssertFalse(result.output.contains("Usage: amoo env"), result.output)
    }
}
