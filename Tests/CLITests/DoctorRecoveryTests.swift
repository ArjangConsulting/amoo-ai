import AmooCore
@testable import CLI
import Foundation
import XCTest

final class DoctorRecoveryTests: XCTestCase {
    func testParsesScopedPreflightAndCleanup() throws {
        let options = try XCTUnwrap(DoctorOptions(arguments: ["--json", "--mcp-pid", "123", "--kill-stale"]))
        XCTAssertEqual(options.mcpPID, 123)
        XCTAssertTrue(options.json)
        XCTAssertTrue(options.killStale)
        XCTAssertTrue(options.includesMCPServer(123))
        XCTAssertFalse(options.includesMCPServer(456))
        let cli = try XCTUnwrap(DoctorOptions(arguments: ["--cli-only", "--json"]))
        XCTAssertTrue(cli.cliOnly)
        XCTAssertFalse(cli.includesMCPServer(123))
    }

    func testRejectsInvalidScopesBeforeRunningDoctor() {
        for arguments in [
            ["--mcp-pid"], ["--mcp-pid", "0"], ["--mcp-pid", "-1"],
            ["--mcp-pid", "abc"], ["--mcp-pid", "999999999999"],
            ["--mcp-pid", "123", "--mcp-pid", "456"],
            ["--cli-only", "--mcp-pid", "123"], ["--cli-only", "--kill-stale"], ["--typo"]
        ] {
            XCTAssertNil(DoctorOptions(arguments: arguments), "\(arguments)")
        }
    }

    func testCLIPreflightKeepsUnrelatedStaleServersVisibleWithoutBlocking() throws {
        var report = makeReport(servers: [server(pid: 123, stale: true)])
        XCTAssertFalse(doctorIssues(report).isEmpty)
        report.cliOnly = true
        XCTAssertTrue(doctorIssues(report).isEmpty)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(renderJSON(report).utf8)) as? [String: Any])
        XCTAssertEqual(json["cli_only"] as? Bool, true)
        XCTAssertEqual((json["mcp_servers"] as? [[String: Any]])?.first?["pid"] as? Int, 123)
    }

    func testMCPPreflightChecksOnlySelectedServerAndRequiresItToExist() {
        var report = makeReport(servers: [server(pid: 123, stale: true), server(pid: 456, stale: false)])
        report.mcpPID = 456
        XCTAssertTrue(doctorIssues(report).isEmpty)
        report.mcpPID = 123
        XCTAssertTrue(doctorIssues(report).contains { $0.contains("runs old code") })
        report.mcpPID = 789
        XCTAssertTrue(doctorIssues(report).contains { $0.contains("not running") && $0.contains("Reconnect") })
    }

    func testCLIPreflightStillFailsForUnhealthyRuntime() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var runtime = try store.start(platform: AmooCore.Platform.ios, deviceID: "SIM")
        runtime.state = .unresponsive
        var report = makeReport(servers: [server(pid: 123, stale: true)])
        report.runtimes = [runtime]
        report.cliOnly = true
        XCTAssertEqual(doctorIssues(report).count, 1)
        XCTAssertTrue(doctorIssues(report)[0].contains("unresponsive"))
    }

    func testCleanupSignalsOnlySelectedStaleServerAfterReinspection() async throws {
        let binary = try makeBinary()
        let runner = makeRunner(binary: binary, rows: [123, 456, 789])
        let reported = await mcpServerProcesses(processRunner: runner)
        var servers = reported
        servers[2].stale = false
        var signalled: [Int32] = []
        let killed = await killStaleMCPServers(
            servers,
            mcpPID: 123,
            processRunner: makeRunner(binary: binary, rows: [123, 456, 789]),
            terminate: { signalled.append($0); return true }
        )
        XCTAssertEqual(killed, [123])
        XCTAssertEqual(signalled, [123])
    }

    func testCleanupRefusesReusedMissingOrChangedProcesses() async throws {
        let binary = try makeBinary()
        let reported = await mcpServerProcesses(processRunner: makeRunner(binary: binary, rows: [123, 456, 789]))
        var changed = reported
        changed[0].startedAt = .distantPast
        changed[1].arguments += " --platform android"
        var signalled: [Int32] = []
        let killed = await killStaleMCPServers(
            changed,
            processRunner: makeRunner(binary: binary, rows: [123, 456]),
            terminate: { signalled.append($0); return true }
        )
        XCTAssertTrue(killed.isEmpty)
        XCTAssertTrue(signalled.isEmpty)
    }

    func testCleanupDoesNotReportFailedSignalAsSuccess() async throws {
        let binary = try makeBinary()
        let reported = await mcpServerProcesses(processRunner: makeRunner(binary: binary, rows: [123]))
        let killed = await killStaleMCPServers(
            reported,
            processRunner: makeRunner(binary: binary, rows: [123]),
            terminate: { _ in false }
        )
        XCTAssertTrue(killed.isEmpty)
    }

    func testCleanupLeavesHealthyServersAndItsOwnProcessAlone() async throws {
        let binary = try makeBinary()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var reported = await mcpServerProcesses(processRunner: makeRunner(binary: binary, rows: [ownPID, 123]))
        reported[1].stale = false
        var signalled: [Int32] = []
        let killed = await killStaleMCPServers(
            reported,
            processRunner: makeRunner(binary: binary, rows: [ownPID, 123]),
            terminate: { signalled.append($0); return true }
        )
        XCTAssertTrue(killed.isEmpty)
        XCTAssertTrue(signalled.isEmpty)
    }

    private func makeReport(servers: [DoctorMCPServer]) -> DoctorReport {
        DoctorReport(
            ok: true,
            cli: .init(version: "test"),
            mcpServers: servers,
            adbServerRunning: false,
            devices: [],
            companions: [],
            runtimes: [],
            issues: [],
            notes: []
        )
    }

    private func server(pid: Int32, stale: Bool) -> DoctorMCPServer {
        .init(pid: pid, binary: "/test/amoo", arguments: "/test/amoo mcp serve", stale: stale)
    }

    private func makeBinary() throws -> URL {
        let binary = try makeScratchDirectory().url.appendingPathComponent("amoo")
        try Data("binary".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: binary.path
        )
        return binary
    }

    private func makeRunner(binary: URL, rows: [Int32]) -> MockCLIProcessRunner {
        let ps = rows.map { "\($0) Thu Sep 24 13:57:17 2026 /test/amoo mcp serve" }.joined(separator: "\n")
        let lsof = rows.map { "p\($0)\nn\(binary.path)" }.joined(separator: "\n")
        return MockCLIProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: ps, stderr: "")),
            .success(.init(exitCode: 0, stdout: lsof, stderr: ""))
        ])
    }
}
