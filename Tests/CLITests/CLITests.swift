import AuditEngine
@testable import CLI
import Foundation
import MCPServer
import ProcessRunner
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

    func testDeviceCommandParsesExplicitSettingsAndArguments() {
        let parsed = parseDeviceCommandOptions(args: [
            "--platform", "ios",
            "--port", "22111",
            "--device", "SIM-123",
            "tap_element",
            "id=login",
            "label=Login"
        ])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertEqual(options.platform, .ios)
        XCTAssertEqual(options.port, 22111)
        XCTAssertEqual(options.deviceID, "SIM-123")
        XCTAssertEqual(options.tool, "tap_element")
        XCTAssertEqual(options.arguments, ["id": "login", "label": "Login"])
    }

    func testDeviceCommandNormalizesAndroidBootedDeviceToNil() {
        let parsed = parseDeviceCommandOptions(args: [
            "--platform", "android",
            "--device", "booted",
            "press_home"
        ])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertNil(options.deviceID)
    }

    func testDeviceCommandRejectsMalformedArgument() {
        let parsed = parseDeviceCommandOptions(args: ["tap", "x=1", "oops"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(error.description, "Malformed argument 'oops'. Expected key=value format.")
    }

    func testDeviceCommandRejectsInvalidPort() {
        let parsed = parseDeviceCommandOptions(args: ["--port", "abc", "tap"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(error.description, "Invalid port 'abc'. Expected a number.")
    }

    func testDeviceCommandRejectsUnknownPlatform() {
        let parsed = parseDeviceCommandOptions(args: ["--platform", "web", "tap"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(error.description, "Unknown platform 'web'. Expected 'ios' or 'android'.")
    }

    func testRunDeviceCommandReturnsConnectionFailureForInvalidPort() async {
        let result = await runDeviceCommand(options: DeviceCommandOptions(
            platform: .ios,
            port: -1,
            deviceID: "booted",
            tool: "tap",
            arguments: ["x": "1", "y": "2"]
        ))

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.output.isEmpty)
    }

    func testCompanionInstallSkipsBuildWhenXCTestRunExists() async throws {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }
        let productsDir = URL(fileURLWithPath: companionDir).appendingPathComponent("build/Build/Products", isDirectory: true)
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: productsDir.appendingPathComponent("MobileTestingCompanion_iphonesimulator.xctestrun").path,
            contents: Data()
        )

        let runner = MockCLIProcessRunner(results: [])
        let manager = CompanionManager(processRunner: runner)
        let config = CompanionConfig(companionDir: companionDir, deviceUDID: "SIM-123")

        try await manager.install(config: config)

        let commands = await runner.recordedCommands()

        XCTAssertEqual(commands, [])
    }

    func testCompanionInstallBuildsWithExpectedCommands() async throws {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: "/opt/homebrew/bin/xcodegen\n", stderr: "")),
            .success(.init(exitCode: 0, stdout: "generated", stderr: "")),
            .success(.init(exitCode: 0, stdout: "built", stderr: ""))
        ])
        let manager = CompanionManager(processRunner: runner)
        let config = CompanionConfig(companionDir: companionDir, deviceUDID: "SIM-123")

        try await manager.install(config: config, force: true)

        let commands = await runner.recordedCommands()

        XCTAssertEqual(commands, [
            ["which", "xcodegen"],
            ["xcodegen", "generate", "--spec", companionDir + "/project.yml"],
            [
                "xcodebuild", "build-for-testing",
                "-scheme", "MobileTestingCompanion",
                "-destination", "platform=iOS Simulator,id=SIM-123",
                "-derivedDataPath", companionDir + "/build",
                "-project", companionDir + "/MobileTestingCompanion.xcodeproj"
            ]
        ])
    }

    func testCompanionInstallThrowsWhenXcodegenIsMissing() async {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 1, stdout: "", stderr: ""))
        ])
        let manager = CompanionManager(processRunner: runner)
        let config = CompanionConfig(companionDir: companionDir, deviceUDID: "SIM-123")

        do {
            try await manager.install(config: config, force: true)
            XCTFail("Expected xcodegen error")
        } catch let error as CompanionError {
            guard case .xcodegeneNotFound = error else {
                return XCTFail("Unexpected companion error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCompanionInstallThrowsBuildFailureOutput() async {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: "/opt/homebrew/bin/xcodegen\n", stderr: "")),
            .success(.init(exitCode: 0, stdout: "generated", stderr: "")),
            .success(.init(exitCode: 65, stdout: "", stderr: "build log"))
        ])
        let manager = CompanionManager(processRunner: runner)
        let config = CompanionConfig(companionDir: companionDir, deviceUDID: "SIM-123")

        do {
            try await manager.install(config: config, force: true)
            XCTFail("Expected build failure")
        } catch let error as CompanionError {
            guard case let .buildFailed(message) = error else {
                return XCTFail("Unexpected companion error: \(error)")
            }
            XCTAssertEqual(message, "build log")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
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

private func makeTemporaryDirectory() -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.path
}

private actor MockCLIProcessRunner: ProcessRunner {
    private var results: [Result<ProcessResult, Error>]
    private var commands: [[String]] = []

    init(results: [Result<ProcessResult, Error>]) {
        self.results = results
    }

    func run(_ arguments: [String]) async throws -> ProcessResult {
        commands.append(arguments)
        guard !results.isEmpty else {
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        return try results.removeFirst().get()
    }

    func recordedCommands() -> [[String]] {
        commands
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
