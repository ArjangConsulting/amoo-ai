import AuditEngine
@testable import CLI
import CLIReadline
import Foundation
import MCPServer
import ProcessRunner
import SwiftyShell
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

    func testHelpCommandReturnsGuidance() async {
        let app = CLIApp()
        let result = await app.run(args: ["help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Usage: amoo <command> [options]"))
        XCTAssertTrue(result.output.contains("Run 'amoo <command>' without enough arguments to see command-specific usage."))
    }

    func testHelpFlagReturnsGuidance() async {
        let app = CLIApp()
        let result = await app.run(args: ["--help"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Commands:"))
        XCTAssertTrue(result.output.contains("amoo device"))
        XCTAssertTrue(result.output.contains("mcp serve"))
        XCTAssertFalse(result.output.contains("amoo ai"))
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
        let parsed = parseMCPServeOptions(args: ["--platform", "android", "--port", "22099", "--device", "emulator-5554"])
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

    func testAvailablePlatformsIncludesOnlyLaunchablePlatforms() {
        XCTAssertEqual(
            test_availablePlatforms(
                iosSimulators: [IOSSimulatorDevice(udid: "SIM-1", name: "iPhone 16", osVersion: "18.0")],
                androidVirtualDevices: []
            ),
            [.ios]
        )

        XCTAssertEqual(
            test_availablePlatforms(
                iosSimulators: [],
                androidVirtualDevices: [AndroidVirtualDevice(name: "Pixel_9")]
            ),
            [.android]
        )

        XCTAssertEqual(
            test_availablePlatforms(
                iosSimulators: [IOSSimulatorDevice(udid: "SIM-1", name: "iPhone 16", osVersion: "18.0")],
                androidVirtualDevices: [AndroidVirtualDevice(name: "Pixel_9")]
            ),
            [.ios, .android]
        )
    }

    func testParseAvailableIOSSimulatorsIncludesShutdownDevices() {
        let simulators = test_parseAvailableIOSSimulators(json: """
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
              {
                "name": "iPhone 16 Pro",
                "udid": "SIM-NEW",
                "state": "Shutdown"
              }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
              {
                "name": "iPhone 15",
                "udid": "SIM-OLD",
                "state": "Booted"
              }
            ]
          }
        }
        """)

        XCTAssertEqual(
            simulators,
            [
                IOSSimulatorDevice(udid: "SIM-OLD", name: "iPhone 15", osVersion: "17.5"),
                IOSSimulatorDevice(udid: "SIM-NEW", name: "iPhone 16 Pro", osVersion: "18.0")
            ]
        )
    }

    func testParseAndroidVirtualDevicesSkipsBlankLines() {
        XCTAssertEqual(
            test_parseAndroidVirtualDevices(output: "\nPixel_9\n\nPixel_Tablet_API_35\n"),
            [
                AndroidVirtualDevice(name: "Pixel_9"),
                AndroidVirtualDevice(name: "Pixel_Tablet_API_35")
            ]
        )
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
        // session_id is auto-injected on every driver-routed tool so MCP
        // clients can scope the call to a specific start_session result.
        XCTAssertEqual(
            catalog.argumentCandidates(for: "tap_element"),
            ["contains_text=", "id=", "label=", "session_id="]
        )
    }

    func testCompletionMatcherPrefersPrefixMatches() {
        XCTAssertEqual(cli_completion_candidate_matches("press_home", "pre", 1), 1)
        XCTAssertEqual(cli_completion_candidate_matches("press_home", "home", 1), 0)
    }

    func testCompletionMatcherFallsBackToContainsMatches() {
        XCTAssertEqual(cli_completion_candidate_matches("press_home", "home", 0), 1)
        XCTAssertEqual(cli_completion_candidate_matches("press_home", "xyz", 0), 0)
    }

    func testPreflightCommandWithFailureReturnsExitCode2() async {
        let app = CLIApp(
            preflightChecker: MockPreflightChecker(
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
            )
        )

        let result = await app.run(args: ["preflight", "--platform", "android"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("preflight FAIL [android]"))
    }

    func testPreflightCommandInvalidPlatformReturnsUsageError() async {
        let app = CLIApp(
            preflightChecker: MockPreflightChecker(report: .init(platform: .all, checks: []))
        )
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
        let result = await runDeviceCommand(
            options: DeviceCommandOptions(
                platform: .ios,
                port: -1,
                deviceID: "booted",
                tool: "tap",
                arguments: ["x": "1", "y": "2"]
            )
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.output.isEmpty)
    }

    func testCompanionInstallSkipsBuildWhenXCTestRunExists() async throws {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }
        let productsDir = URL(fileURLWithPath: companionDir).appendingPathComponent(
            "build/Build/Products", isDirectory: true
        )
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: productsDir.appendingPathComponent("AmooCompanion_iphonesimulator.xctestrun")
                .path,
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
            .success(.init(exitCode: 0, stdout: "generated", stderr: "")),
            .success(.init(exitCode: 0, stdout: "built", stderr: ""))
        ])
        let manager = CompanionManager(processRunner: runner)
        let config = CompanionConfig(companionDir: companionDir, deviceUDID: "SIM-123")

        try await manager.install(config: config, force: true)

        let commands = await runner.recordedCommands()

        XCTAssertEqual(
            commands,
            [
                ["xcodegen", "generate", "--spec", companionDir + "/project.yml"],
                [
                    "xcodebuild",
                    "-scheme", "AmooCompanion",
                    "-destination", "platform=iOS Simulator,id=SIM-123",
                    "-derivedDataPath", companionDir + "/build",
                    "-project", companionDir + "/AmooCompanion.xcodeproj",
                    "build-for-testing"
                ]
            ]
        )
    }

    func testCompanionInstallThrowsWhenXcodegenIsMissing() async {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }

        let runner = MockCLIProcessRunner(results: [
            .failure(ShellError.commandNotFound("xcodegen"))
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

    func testCompanionCommandParserDefaultsAndFlags() {
        let parsed = parseCompanionCommandOptions(args: [
            "install",
            "--platform", "android",
            "--device", "emulator-5554",
            "--companion-dir", "/tmp/android-companion",
            "--force"
        ])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertEqual(options.platform, .android)
        XCTAssertEqual(options.deviceID, "emulator-5554")
        XCTAssertEqual(options.companionDir, "/tmp/android-companion")
        XCTAssertTrue(options.force)
    }

    func testCompanionCommandParserRejectsUnknownAction() {
        let parsed = parseCompanionCommandOptions(args: ["launch"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(
            error.description,
            "Unknown companion action 'launch'. Run 'amoo companion' for usage."
        )
    }

    func testCompanionCommandParserRejectsUnknownPlatform() {
        let parsed = parseCompanionCommandOptions(args: ["install", "--platform", "desktop"])
        guard case let .failure(error) = parsed else {
            return XCTFail("Expected parser failure")
        }

        XCTAssertEqual(error.description, "Unknown platform 'desktop'. Expected 'ios' or 'android'.")
    }

    func testRunIOSCompanionInstallReturnsFailureDescription() async {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }

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
        XCTAssertEqual(result.output, CompanionError.xcodegeneNotFound.description)
    }

    func testRunAndroidCompanionInstallBuildFailureUsesProcessOutput() async {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }

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

    func testRunAndroidCompanionInstallFailsWhenAPKInstallFails() async {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }
        try? createAndroidAPKFixtures(at: companionDir)

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 1, stdout: "INSTALL_FAILED", stderr: ""))
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
        XCTAssertTrue(result.output.contains("Failed to install Android app APK:"))
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.prefix(5), ["adb", "-s", "emulator-5554", "install", "-r"])
    }

    func testRunAndroidCompanionInstallSucceedsWithExistingArtifacts() async throws {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }
        try createAndroidAPKFixtures(at: companionDir)

        let runner = MockCLIProcessRunner(results: [
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
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0][0 ... 2], ["adb", "install", "-r"])
        XCTAssertEqual(commands[1][0 ... 2], ["adb", "install", "-r"])
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
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.path
}

private func createAndroidAPKFixtures(at companionDir: String) throws {
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
