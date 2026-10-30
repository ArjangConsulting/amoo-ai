import AuditEngine
@testable import CLI
import Foundation
import MCPServer
import ProcessRunner
import SwiftyShell
import TestCommons
import XCTest

extension CLITests {
    func testRunIOSCompanionInstallReturnsFailureDescription() async throws {
        let companionDir = try makeTemporaryDirectory()

        let runner = MockCLIProcessRunner(results: [
            .failure(ShellError.commandNotFound("xcodegen"))
        ])
        let result = await runIOSCompanionInstall(
            options: CompanionCommandOptions(
                action: .install,
                platform: .ios,
                deviceID: "SIM-123",
                companionDir: companionDir,
                force: true
            ),
            processRunner: runner
        )

        XCTAssertEqual(result.exitCode, 1)
        #if os(macOS)
        XCTAssertEqual(result.output, CompanionError.xcodegeneNotFound.description)
        #else
        // `buildForTesting` never reaches the injected process runner on Linux — it fails fast
        // with `.unsupportedPlatform` instead, since XcodeGen/XcodeBuild aren't usable there.
        XCTAssertEqual(result.output, CompanionError.unsupportedPlatform.description)
        #endif
    }

    func testRunAndroidCompanionInstallBuildFailureUsesProcessOutput() async throws {
        let companionDir = try makeTemporaryDirectory()

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 1, stdout: "gradle failed", stderr: ""))
        ])
        let result = await runAndroidCompanionInstall(
            options: CompanionCommandOptions(
                action: .install,
                platform: .android,
                deviceID: "booted",
                companionDir: companionDir,
                force: true
            ),
            processRunner: runner,
            currentDirectory: companionDir
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Android companion build failed:"))
        XCTAssertTrue(result.output.contains("gradle failed"))
    }

    func testRunAndroidCompanionInstallFailsWhenAPKInstallFails() async throws {
        let companionDir = try makeTemporaryDirectory()
        try? createAndroidAPKFixtures(at: companionDir)

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: "35\n", stderr: "")),
            .success(.init(
                exitCode: 1,
                stdout: "",
                stderr: "adb: failed to install app.apk: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"
            ))
        ])
        let result = await runAndroidCompanionInstall(
            options: CompanionCommandOptions(
                action: .install,
                platform: .android,
                deviceID: "emulator-5554",
                companionDir: companionDir,
                force: false
            ),
            processRunner: runner,
            currentDirectory: companionDir
        )

        let commands = await runner.recordedCommands()
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Failed to install Android app APK on emulator-5554, API 35:"))
        XCTAssertTrue(result.output.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE"))
        XCTAssertTrue(result.output.contains("Likely cause:"))
        XCTAssertTrue(result.output.contains("Recovery:"))
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last?.prefix(5), ["adb", "-s", "emulator-5554", "install", "-r"])
    }

    func testRunAndroidCompanionInstallRemovesItsOwnPackagesOnceAfterASignatureClash() async throws {
        let companionDir = try makeTemporaryDirectory()
        try createAndroidAPKFixtures(at: companionDir)

        let clash = "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]"
        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: "37\n", stderr: "")),
            .success(.init(exitCode: 1, stdout: "", stderr: clash)),
            .success(.init(exitCode: 0, stdout: "Success", stderr: "")),
            .success(.init(exitCode: 0, stdout: "Success", stderr: "")),
            .success(.init(exitCode: 0, stdout: "Success", stderr: "")),
            .success(.init(exitCode: 0, stdout: "Success", stderr: ""))
        ])
        let result = await runAndroidCompanionInstall(
            options: CompanionCommandOptions(
                action: .install,
                platform: .android,
                deviceID: "emulator-5554",
                companionDir: companionDir,
                force: false
            ),
            processRunner: runner,
            currentDirectory: companionDir
        )

        let commands = await runner.recordedCommands()
        let verbs = commands.map { $0.dropFirst(3).first }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(verbs, ["shell", "install", "uninstall", "uninstall", "install", "install"])
        let removed = commands.filter { $0.contains("uninstall") }.compactMap(\.last)
        XCTAssertEqual(removed, ["com.amoo.companion.test", "com.amoo.companion"])
    }

    func testRunAndroidCompanionInstallRefusesADeviceBelowTheMinimumAPILevelBeforeInstalling() async throws {
        let companionDir = try makeTemporaryDirectory()
        try createAndroidAPKFixtures(at: companionDir)

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: "24\n", stderr: ""))
        ])
        let result = await runAndroidCompanionInstall(
            options: CompanionCommandOptions(
                action: .install,
                platform: .android,
                deviceID: "emulator-5554",
                companionDir: companionDir,
                force: false
            ),
            processRunner: runner,
            currentDirectory: companionDir
        )

        let commands = await runner.recordedCommands()
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("API 24"))
        XCTAssertTrue(result.output.contains("API \(AndroidCompanionConfig.minimumAPILevel)"))
        XCTAssertEqual(commands.count, 1)
    }

    func testRunAndroidCompanionInstallSucceedsWithExistingArtifacts() async throws {
        let companionDir = try makeTemporaryDirectory()
        try createAndroidAPKFixtures(at: companionDir)

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: "35\n", stderr: "")),
            .success(.init(exitCode: 0, stdout: "Success", stderr: "")),
            .success(.init(exitCode: 0, stdout: "Success", stderr: ""))
        ])
        let result = await runAndroidCompanionInstall(
            options: CompanionCommandOptions(
                action: .install,
                platform: .android,
                deviceID: "booted",
                companionDir: companionDir,
                force: false
            ),
            processRunner: runner,
            currentDirectory: companionDir
        )

        let commands = await runner.recordedCommands()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0][0 ... 2], ["adb", "shell", "getprop"])
        XCTAssertEqual(commands[1][0 ... 2], ["adb", "install", "-r"])
        XCTAssertEqual(commands[2][0 ... 2], ["adb", "install", "-r"])
    }

    func testREPLShellSplitHandlesQuotedArguments() {
        let split = test_shellSplit("tap_element \"Sign In\" label='Primary CTA'")

        XCTAssertEqual(split.toolName, "tap_element")
        XCTAssertEqual(split.parts, ["Sign In", "label=Primary CTA"])
    }

    func testREPLClosestToolSuggestsNearMatch() {
        let suggestion = test_closestTool(to: "scrll", among: ["scroll", "tap", "type_text"])
        let none = test_closestTool(to: "banana", among: ["scroll", "tap", "type_text"])

        XCTAssertEqual(suggestion, "scroll")
        XCTAssertNil(none)
    }

    func testREPLBuiltinToolsIsHandledWithoutDispatch() async {
        let definitions = MCPServer().toolDefinitions()
        let result = await test_handleBuiltin("tools", toolDefinitions: definitions)

        XCTAssertEqual(result, "handled")
    }

    func testREPLBannerStyleFallsBackForDumbTerminal() {
        XCTAssertEqual(test_replBannerStyle(environment: ["TERM": "dumb", "LANG": "en_US.UTF-8"]), "+")
        XCTAssertEqual(test_replBannerStyle(environment: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]), "╭")
    }

    func testAuditCommandWritesArtifactsAndReturnsSuccess() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let tempDir = scratch.url
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
