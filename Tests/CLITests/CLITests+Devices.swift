import AuditEngine
@testable import CLI
import CLIReadline
import Foundation
import MCPServer
import ProcessRunner
import SwiftyShell
import XCTest

extension CLITests {
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

    func testParseConnectedIOSDevicesOnlyReturnsTunnelledIOSDevices() {
        let devices = test_parseConnectedIOSDevices(json: """
        {
          "result": {
            "devices": [
              {
                "identifier": "ID-1",
                "deviceProperties": { "name": "Mani's iPhone", "osVersionNumber": "18.2" },
                "hardwareProperties": { "udid": "UDID-1", "platform": "iOS" },
                "connectionProperties": { "tunnelState": "connected" }
              },
              {
                "identifier": "ID-2",
                "deviceProperties": { "name": "Unplugged iPhone", "osVersionNumber": "18.1" },
                "hardwareProperties": { "udid": "UDID-2", "platform": "iOS" },
                "connectionProperties": { "tunnelState": "unavailable" }
              },
              {
                "identifier": "ID-3",
                "deviceProperties": { "name": "Mani's Watch", "osVersionNumber": "11.0" },
                "hardwareProperties": { "udid": "UDID-3", "platform": "watchOS" },
                "connectionProperties": { "tunnelState": "connected" }
              }
            ]
          }
        }
        """)

        // Unplugged devices can't be driven, and devicectl also reports paired Watches
        // and Apple TVs — offering either would only fail later.
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.udid, "UDID-1")
        XCTAssertEqual(devices.first?.name, "Mani's iPhone")
        XCTAssertEqual(devices.first?.osVersion, "18.2")
        XCTAssertTrue(devices.first?.isPhysicalDevice ?? false)
    }

    func testParseConnectedIOSDevicesSurvivesMalformedJSON() {
        XCTAssertTrue(test_parseConnectedIOSDevices(json: "not json").isEmpty)
        XCTAssertTrue(test_parseConnectedIOSDevices(json: #"{"result":{}}"#).isEmpty)
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
        // scope/bundle_id resolve the element in another process — system UI hosts permission
        // alerts and the Sign in with Apple sheet, which are absent from the app's own tree.
        XCTAssertEqual(
            catalog.argumentCandidates(for: "tap_element"),
            ["bundle_id=", "contains_text=", "id=", "label=", "parent_id=", "scope=", "session_id="]
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

    func testDeviceCommandCollectsRepeatedEnvFlags() {
        let parsed = parseDeviceCommandOptions(args: [
            "device_launch_app",
            "app_id=com.example.app",
            "--env", "UITEST=1",
            "--env", "API_HOST=http://localhost:8080"
        ])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertEqual(options.arguments["app_id"], "com.example.app")
        // Newline-joined, with a trailing newline marking the string as newline-separated.
        XCTAssertEqual(
            options.arguments["environment"],
            "UITEST=1\nAPI_HOST=http://localhost:8080\n"
        )
        XCTAssertEqual(
            DriverToolExecutor.parseEnvironment(options.arguments["environment"]),
            ["UITEST": "1", "API_HOST": "http://localhost:8080"]
        )
    }

    func testDeviceCommandKeepsCommasInsideEnvValues() {
        let parsed = parseDeviceCommandOptions(args: [
            "device_launch_app",
            "app_id=com.example.app",
            "--env", "LOCALES=en,fr,de"
        ])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        let environment = DriverToolExecutor.parseEnvironment(
            options.arguments["environment"]
        )
        XCTAssertEqual(environment, ["LOCALES": "en,fr,de"])
    }

    func testDeviceCommandRejectsEnvWithoutAssignment() {
        let parsed = parseDeviceCommandOptions(args: [
            "device_launch_app", "app_id=com.example.app", "--env", "UITEST"
        ])
        guard case .failure = parsed else {
            return XCTFail("Expected parser failure for --env without KEY=VALUE")
        }
    }

    func testDeviceCommandCollectsRepeatedArgFlags() {
        let parsed = parseDeviceCommandOptions(args: [
            "device_launch_app", "app_id=com.example.app", "--arg", "-uitest", "--arg", "fast"
        ])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected parser success")
        }

        XCTAssertEqual(options.arguments["launch_args"], "-uitest,fast")
    }

    /// The comma form MCP clients send keeps working alongside the newline form.
    func testEnvironmentParsingAcceptsCommaSeparatedPairs() {
        let environment = DriverToolExecutor.parseEnvironment("UITEST=1,STAGE=test")
        XCTAssertEqual(environment, ["UITEST": "1", "STAGE": "test"])
    }
}
