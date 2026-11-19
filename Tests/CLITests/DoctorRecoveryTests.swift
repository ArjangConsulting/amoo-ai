import AmooCore
@testable import CLI
import Foundation
import XCTest

final class DoctorRecoveryTests: XCTestCase {
    func testOldTemplatesMayStillPassCLIOnly() {
        XCTAssertEqual(DoctorOptions(arguments: ["--cli-only", "--json"])?.json, true)
        XCTAssertNil(DoctorOptions(arguments: ["--mcp-pid", "123"]), "MCP recovery flags are gone")
        XCTAssertNil(DoctorOptions(arguments: ["--kill-stale"]))
    }

    func testUnhealthyRuntimeFailsTheCheck() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var runtime = try store.start(platform: AmooCore.Platform.ios, deviceID: "SIM")
        runtime.state = .unresponsive
        var report = makeReport()
        report.runtimes = [runtime]

        applyDoctorDiagnostics(&report, simulatorRuntimeProblems: ["iPhone Duo cannot boot."])

        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertTrue(report.issues[0].contains("unresponsive"))
    }

    func testUnavailableSimulatorInventoryIsAdvisory() throws {
        var report = makeReport()
        let problem = "iPhone Duo cannot boot: runtime profile not found."

        applyDoctorDiagnostics(&report, simulatorRuntimeProblems: [problem])

        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.notes.contains(problem))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(renderJSON(report).utf8)) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertNil(json["mcp_servers"])
        XCTAssertTrue((json["notes"] as? [String])?.contains(problem) == true)
        XCTAssertTrue(humanDoctorSummary(report).contains(problem))
    }

    private func makeReport() -> DoctorReport {
        DoctorReport(
            ok: true,
            cli: .init(version: "test"),
            adbServerRunning: false,
            devices: [],
            companions: [],
            runtimes: [],
            issues: [],
            notes: []
        )
    }
}
