import AuditEngine
@testable import CLI
import Foundation
import MCPServer
import XCTest

final class CLITests: XCTestCase {
    func testDefaultOutput() async {
        // REPL mode (no subcommand): prints nothing to CLIResult, exits 0 after device selection fails silently
        let app = CLIApp()
        let result = await app.run(args: [])
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testToolsOutput() async {
        let app = CLIApp()
        let result = await app.run(args: ["--tools"])
        XCTAssertTrue(result.output.contains("tap"))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testREPLCompletionCatalogIncludesBuiltinsAndToolNames() {
        let catalog = REPLCompletionCatalog(toolDefinitions: [
            ToolDefinition(name: "tap", description: "Tap"),
            ToolDefinition(name: "scroll", description: "Scroll")
        ])

        XCTAssertEqual(catalog.rootCandidates, ["?", "exit", "help", "quit", "scroll", "tap", "tools"])
    }

    func testREPLCompletionCatalogUsesSortedKeyValueArguments() {
        let catalog = REPLCompletionCatalog(toolDefinitions: [
            ToolDefinition(
                name: "take_screenshot",
                description: "Capture a screenshot",
                properties: [
                    "output": .init(type: "string", description: "Output path"),
                    "format": .init(type: "string", description: "Image format")
                ]
            )
        ])

        XCTAssertEqual(catalog.argumentCandidates(for: "take_screenshot"), ["format=", "output="])
    }

    func testREPLCompletionCatalogIncludesTapElementTool() {
        let catalog = REPLCompletionCatalog(toolDefinitions: MCPServer().toolDefinitions())
        XCTAssertTrue(catalog.rootCandidates.contains("tap_element"))
        XCTAssertEqual(catalog.argumentCandidates(for: "tap_element"), ["contains_text=", "id=", "label="])
    }

    #if os(macOS)
    func testCompanionLaunchProcessPassesConfiguredPort() {
        let manager = CompanionManager()
        let config = CompanionConfig(port: 22111, deviceUDID: "SIM-123")

        let process = manager.makeCompanionLaunchProcess(xctestrunPath: "/tmp/test.xctestrun", config: config)

        XCTAssertEqual(process.environment?["COMPANION_PORT"], "22111")
    }
    #endif

    func testPreflightCommandWithFailureReturnsExitCode2() async {
        let app = CLIApp(preflightChecker: MockPreflightChecker(
            report: PreflightReport(
                platform: .android,
                checks: [
                    .init(
                        id: "android.adb",
                        status: .fail,
                        message: "adb not found",
                        remediation: "install platform-tools"
                    )
                ]
            )
        ))

        let result = await app.run(args: ["preflight", "--platform", "android"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("preflight FAIL [android]"))
    }

    func testPreflightCommandInvalidPlatformReturnsUsageError() async {
        let app = CLIApp(preflightChecker: MockPreflightChecker(report: .init(platform: .all, checks: [])))
        let result = await app.run(args: ["preflight", "--platform", "desktop"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("Invalid platform"))
    }

    func testDeviceCommandDefaultsToIOSPlatform() {
        let parsed = parseDeviceCommandOptions(args: ["tap", "x=1", "y=2"])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertEqual(options.platform, .ios)
        XCTAssertEqual(options.port, 22087)
        XCTAssertEqual(options.deviceID, "booted")
    }

    func testDeviceCommandUsesAndroidDefaults() {
        let parsed = parseDeviceCommandOptions(args: ["--platform", "android", "press_home"])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertEqual(options.platform, .android)
        XCTAssertEqual(options.port, 22088)
        XCTAssertNil(options.deviceID)
    }

    func testAuditCommandWritesArtifactsAndReturnsSuccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let jsonPath = tempDir.appendingPathComponent("audit.json").path
        let markdownPath = tempDir.appendingPathComponent("audit.md").path

        let report = AuditReport(
            appID: "com.example.app",
            findings: [makeFinding(id: "finding-1", severity: .low)]
        )
        let app = CLIApp(
            preflightChecker: MockPreflightChecker(report: .init(platform: .all, checks: [])),
            auditRunner: MockAuditRunner(report: report)
        )

        let result = await app.run(args: [
            "audit",
            "--app-id", "com.example.app",
            "--screen-summary", "home screen",
            "--root-id", "root",
            "--fail-on", "high",
            "--out-json", jsonPath,
            "--out-md", markdownPath
        ])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markdownPath))

        let json = try String(contentsOfFile: jsonPath, encoding: .utf8)
        let markdown = try String(contentsOfFile: markdownPath, encoding: .utf8)
        XCTAssertTrue(json.contains("\"appID\" : \"com.example.app\""))
        XCTAssertTrue(json.contains("\"failOn\" : \"high\""))
        XCTAssertTrue(markdown.contains("# Audit Report"))
        XCTAssertTrue(markdown.contains("Fail Policy: `high`"))
    }

    func testAuditCommandReturnsPolicyFailureExitCode() async {
        let report = AuditReport(
            appID: "com.example.app",
            findings: [makeFinding(id: "finding-2", severity: .high)]
        )
        let app = CLIApp(
            preflightChecker: MockPreflightChecker(report: .init(platform: .all, checks: [])),
            auditRunner: MockAuditRunner(report: report)
        )

        let result = await app.run(args: ["audit", "--app-id", "com.example.app", "--fail-on", "high"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("Total Findings: `1`"))
    }

    func testAuditCommandInvalidArgumentsReturnUsageError() async {
        let app = CLIApp(
            preflightChecker: MockPreflightChecker(report: .init(platform: .all, checks: [])),
            auditRunner: MockAuditRunner(report: .init(appID: "com.example", findings: []))
        )

        let result = await app.run(args: ["audit", "--fail-on", "extreme"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("Invalid --fail-on value"))
    }

    private func makeFinding(id: String, severity: Severity) -> AuditFinding {
        AuditFinding(
            id: id,
            ruleID: "RULE-001",
            severity: severity,
            confidence: 0.8,
            summary: "Sample finding",
            remediation: "Fix issue",
            evidence: [
                AuditEvidence(
                    kind: .trace,
                    summary: "Trace sample",
                    sourceRef: "trace-ref",
                    attributes: [:]
                )
            ],
            tags: ["security"]
        )
    }
}

private struct MockPreflightChecker: PreflightChecking {
    let report: PreflightReport

    func run(platform _: PreflightPlatform) async -> PreflightReport {
        report
    }
}

private struct MockAuditRunner: AuditRunning {
    let report: AuditReport

    func runAudit(options _: AuditCommandOptions) async throws -> AuditReport {
        report
    }
}
