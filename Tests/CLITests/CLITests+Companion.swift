import AuditEngine
@testable import CLI
import CLIReadline
import Foundation
import MCPServer
import ProcessRunner
import SwiftyShell
import XCTest

extension CLITests {
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
        try manager.currentSourceFingerprint(config: config).write(
            toFile: companionDir + "/build/.amoo-source-fingerprint",
            atomically: true,
            encoding: .utf8
        )

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

        #if os(macOS)
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
        #else
        // `buildForTesting` never reaches the injected process runner on Linux — it fails fast
        // with `.unsupportedPlatform` instead, since XcodeGen/XcodeBuild aren't usable there.
        do {
            try await manager.install(config: config, force: true)
            XCTFail("Expected unsupportedPlatform error")
        } catch let error as CompanionError {
            guard case .unsupportedPlatform = error else {
                return XCTFail("Unexpected companion error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        #endif
    }

    func testCompanionInstallBuildsForPhysicalDeviceDestination() async throws {
        let companionDir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: companionDir) }

        let runner = MockCLIProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: "generated", stderr: "")),
            .success(.init(exitCode: 0, stdout: "built", stderr: ""))
        ])
        let manager = CompanionManager(processRunner: runner)
        let config = CompanionConfig(
            companionDir: companionDir,
            deviceUDID: "PHONE-123",
            isPhysicalDevice: true
        )

        #if os(macOS)
        try await manager.install(config: config, force: true)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(
            commands[1],
            [
                "xcodebuild",
                "-scheme", "AmooCompanion",
                "-destination", "platform=iOS,id=PHONE-123",
                "-derivedDataPath", companionDir + "/build",
                "-project", companionDir + "/AmooCompanion.xcodeproj",
                "build-for-testing"
            ]
        )
        #endif
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
            #if os(macOS)
            guard case .xcodegeneNotFound = error else {
                return XCTFail("Unexpected companion error: \(error)")
            }
            #else
            // `buildForTesting` fails fast with `.unsupportedPlatform` on Linux, never reaching
            // the injected process runner that would have surfaced `.xcodegeneNotFound`.
            guard case .unsupportedPlatform = error else {
                return XCTFail("Unexpected companion error: \(error)")
            }
            #endif
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
            #if os(macOS)
            guard case let .buildFailed(message) = error else {
                return XCTFail("Unexpected companion error: \(error)")
            }
            XCTAssertEqual(message, "build log")
            #else
            // `buildForTesting` fails fast with `.unsupportedPlatform` on Linux, never reaching
            // the injected process runner that would have surfaced `.buildFailed`.
            guard case .unsupportedPlatform = error else {
                return XCTFail("Unexpected companion error: \(error)")
            }
            #endif
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
}
