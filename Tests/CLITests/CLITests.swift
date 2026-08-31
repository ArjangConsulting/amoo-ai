import AmooCore
import AuditEngine
@testable import CLI
import CLIReadline
import Foundation
import MCPServer
import ProcessRunner
import SwiftyShell
import XCTest

final class CLITests: XCTestCase {
    func testCLIVersionUsesTheSharedAmooVersion() async {
        XCTAssertEqual(CLIApp.versionString, AmooVersion.current)
        let result = await CLIApp().run(args: ["--version"])
        XCTAssertEqual(result.output, AmooVersion.current)
    }

    func testFlowJSONDecodesReusableSteps() throws {
        let data = Data("""
        {
          "platform": "ios",
          "device_id": "booted",
          "steps": [
            { "name": "Open account", "tool": "tap_element", "arguments": { "id": "account" } },
            { "tool": "assert_enabled", "arguments": { "id": "sign-in" } }
          ]
        }
        """.utf8)

        let flow = try JSONDecoder().decode(TestFlow.self, from: data)

        XCTAssertEqual(flow.platform, "ios")
        XCTAssertEqual(flow.deviceID, "booted")
        XCTAssertEqual(flow.steps.map(\.tool), ["tap_element", "assert_enabled"])
    }

    func testDefaultCompanionDirectoryResolvesFromInstalledExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".build/debug/amoo")
        let companion = root.appendingPathComponent("CompanionApps/iOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: true)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: companion.appendingPathComponent("project.yml").path,
                contents: Data()
            )
        )

        let resolved = CompanionConfig.defaultCompanionDir(
            executableURL: executable,
            currentDirectoryPath: "/tmp/unrelated-project"
        )

        XCTAssertEqual(resolved, companion.path)
    }

    func testAndroidDefaultCompanionDirectoryResolvesFromInstalledExecutable() throws {
        // The Android twin of the iOS case above. It regressed independently: the iOS side was
        // fixed while Android kept resolving against the CWD, so `amoo companion start
        // --platform android` from any other project looked for gradlew under that project.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".build/debug/amoo")
        let companion = root.appendingPathComponent("CompanionApps/Android", isDirectory: true)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: true)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: companion.appendingPathComponent("gradlew").path,
                contents: Data()
            )
        )

        let resolved = AndroidCompanionConfig.defaultCompanionDir(
            executableURL: executable,
            currentDirectoryPath: "/tmp/unrelated-project"
        )

        XCTAssertEqual(resolved, companion.path)
    }

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

    func testHelpCommandReturnsGuidance() async {
        let app = CLIApp()
        let result = await app.run(args: ["help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Usage: amoo <command> [options]"))
        XCTAssertTrue(result.output
            .contains("Run 'amoo <command>' without enough arguments to see command-specific usage."))
    }

    func testHelpFlagReturnsGuidance() async {
        let app = CLIApp()
        let result = await app.run(args: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Commands:"))
        XCTAssertTrue(result.output.contains("amoo device"))
        XCTAssertTrue(result.output.contains("mcp serve"))
        XCTAssertTrue(result.output.contains("studio serve"))
        XCTAssertFalse(result.output.contains("amoo ai"))
    }

    func testStudioSubcommandHelpReturnsUsageWithoutStartingService() async {
        let result = await CLIApp().run(args: ["studio", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "Usage: amoo studio serve")
    }

    func testShortHelpFlagReturnsGuidance() async {
        let app = CLIApp()
        let result = await app.run(args: ["-h"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Usage: amoo <command> [options]"))
        XCTAssertTrue(result.output.contains("amoo --help"))
    }

    func testDeviceSubcommandHelpFlagReturnsDeviceHelp() async {
        let app = CLIApp()
        let result = await app.run(args: ["device", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Usage: amoo device"))
        XCTAssertFalse(result.output.contains("Usage: amoo <command> [options]"))
    }

    func testDeviceSubcommandShortHelpReturnsDeviceHelp() async {
        let app = CLIApp()
        let result = await app.run(args: ["device", "-h"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Usage: amoo device"))
        XCTAssertTrue(result.output.contains("suggest_test_actions"))
    }

    func testCompanionSubcommandHelpCommandReturnsCompanionHelp() async {
        let app = CLIApp()
        let result = await app.run(args: ["companion", "help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Usage: amoo companion"))
    }

    func testAuditSubcommandHelpFlagReturnsAuditHelp() async {
        let app = CLIApp()
        let result = await app.run(args: ["audit", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Usage: amoo audit"))
    }

    func testMCPSubcommandShortHelpReturnsMCPHelp() async {
        let app = CLIApp()
        let result = await app.run(args: ["mcp", "-h"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "Usage: amoo mcp serve [--platform ios|android] [--port <port>] [--device <id>]")
    }

    func testPreflightSubcommandHelpFlagReturnsPreflightHelp() async {
        let app = CLIApp()
        let result = await app.run(args: ["preflight", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "Usage: amoo preflight [--platform ios|android|all]")
    }

    func testNestedHelpAfterSubcommandActionReturnsSubcommandHelp() async {
        let app = CLIApp()
        let result = await app.run(args: ["mcp", "serve", "--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "Usage: amoo mcp serve [--platform ios|android] [--port <port>] [--device <id>]")
    }

    func testMCPServeOptionsDefaultsToIOS() {
        let parsed = parseMCPServeOptions(args: [])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertEqual(options.platform, .ios)
        XCTAssertEqual(options.port, 22087)
        XCTAssertEqual(options.deviceID, "booted")
    }

    func testMCPServeOptionsParsesAndroid() {
        let parsed = parseMCPServeOptions(args: [
            "--platform",
            "android",
            "--port",
            "22099",
            "--device",
            "emulator-5554"
        ])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertEqual(options.platform, .android)
        XCTAssertEqual(options.port, 22099)
        XCTAssertEqual(options.deviceID, "emulator-5554")
    }

    func testMCPServeOptionsRejectsUnknownPlatform() {
        let parsed = parseMCPServeOptions(args: ["--platform", "web"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(error.description, "Unknown platform 'web'. Expected 'ios' or 'android'.")
    }

    func testMCPServeOptionsRejectsInvalidPort() {
        let parsed = parseMCPServeOptions(args: ["--port", "not-a-port"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(error.description, "Invalid port 'not-a-port'. Expected a number.")
    }

    func testMCPServeOptionsRejectsMissingOptionValue() {
        let parsed = parseMCPServeOptions(args: ["--device"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(error.description, "Missing value for --device.")
    }

    func testMCPServeOptionsRejectsUnknownFlag() {
        let parsed = parseMCPServeOptions(args: ["--transport", "http"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(error.description, "Unknown option '--transport'.")
    }
}

func makeTemporaryDirectory() -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.path
}

func createAndroidAPKFixtures(at companionDir: String) throws {
    let appPath = URL(fileURLWithPath: companionDir)
        .appendingPathComponent("app/build/outputs/apk/debug", isDirectory: true)
    let testPath = URL(fileURLWithPath: companionDir)
        .appendingPathComponent("app/build/outputs/apk/androidTest/debug", isDirectory: true)
    try FileManager.default.createDirectory(at: appPath, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: testPath, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: appPath.appendingPathComponent("app-debug.apk").path, contents: Data()
    )
    FileManager.default.createFile(
        atPath: testPath.appendingPathComponent("app-debug-androidTest.apk").path, contents: Data()
    )
}

actor MockCLIProcessRunner: ProcessRunner {
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

struct MockPreflightChecker: PreflightChecking {
    let report: PreflightReport

    func run(platform _: PreflightPlatform) async -> PreflightReport {
        report
    }
}

struct MockAuditRunner: AuditRunning {
    let report: AuditReport

    func runAudit(options _: AuditCommandOptions) async throws -> AuditReport {
        report
    }
}
