import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import XCTest

/// Argument-level tests for ``DeviceCtlRunner``.
///
/// These assert the exact argv handed to `xcrun devicectl`, because that is the whole
/// contract of this type — a wrong subcommand or flag name only surfaces against real
/// hardware, which CI never has.
final class DeviceCtlRunnerTests: XCTestCase {
    // MARK: - Command Construction

    func testRunPrefixesXcrunDevicectl() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "{}", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        _ = try await runner.run(["list", "devices"])

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands, [["xcrun", "devicectl", "list", "devices"]])
    }

    func testRunRejectsEmptyCommand() async throws {
        let runner = DeviceCtlRunner()
        do {
            _ = try await runner.run([])
            XCTFail("Expected empty command to fail")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .emptyCommand)
        }
    }

    func testListDevicesRequestsJSONOnStdout() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "{}", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        _ = try await runner.listDevices()

        let commands = await mock.recordedCommands()
        // JSON is devicectl's versioned contract; its table output is explicitly unstable.
        XCTAssertEqual(commands, [["xcrun", "devicectl", "list", "devices", "--json-output", "-"]])
    }

    func testAppLifecycleCommands() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.install(device: "UDID-1", appPath: "/tmp/App.app")
        try await runner.uninstall(device: "UDID-1", appID: "com.example.app")
        _ = try await runner.listApps(device: "UDID-1")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], [
            "xcrun", "devicectl", "device", "install", "app", "--device", "UDID-1", "/tmp/App.app"
        ])
        XCTAssertEqual(commands[1], [
            "xcrun", "devicectl", "device", "uninstall", "app", "--device", "UDID-1", "com.example.app"
        ])
        XCTAssertEqual(commands[2], [
            "xcrun", "devicectl", "device", "info", "apps",
            "--device", "UDID-1", "--json-output", "-"
        ])
    }

    func testLaunchTerminatesExistingAndForwardsArgumentsAfterBundleID() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.launch(
            device: "UDID-1",
            appID: "com.example.app",
            arguments: ["--uitest", "fast"],
            environment: [:]
        )

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], [
            "xcrun", "devicectl", "device", "process", "launch",
            "--device", "UDID-1",
            "--terminate-existing",
            "com.example.app",
            // Anything after the bundle identifier is forwarded to the app, so ordering matters.
            "--uitest", "fast"
        ])
    }

    func testLaunchEncodesEnvironmentAsSingleJSONArgument() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.launch(
            device: "UDID-1",
            appID: "com.example.app",
            arguments: [],
            environment: ["MODE": "test"]
        )

        let commands = await mock.recordedCommands()
        guard let flagIndex = commands[0].firstIndex(of: "--environment-variables") else {
            return XCTFail("Expected --environment-variables flag, got \(commands[0])")
        }
        // devicectl takes the whole environment as one JSON object argument, not repeated flags.
        XCTAssertEqual(commands[0][flagIndex + 1], #"{"MODE":"test"}"#)
        XCTAssertEqual(commands[0].last, "com.example.app")
    }

    func testLaunchOmitsEnvironmentFlagWhenEmpty() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.launch(device: "UDID-1", appID: "com.example.app", arguments: [], environment: [:])

        let commands = await mock.recordedCommands()
        XCTAssertFalse(commands[0].contains("--environment-variables"))
    }

    // MARK: - Terminate

    func testTerminateLooksUpPIDThenSignalsIt() async throws {
        let processes = """
        {
          "result": {
            "runningProcesses": [
              {
                "processIdentifier": 4321,
                "executable": "file:///private/var/containers/Bundle/Application/X/app.app/app"
              }
            ]
          }
        }
        """
        let mock = MockShellExecutor(results: [
            .init(exitCode: 0, stdout: processes, stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.terminate(device: "UDID-1", appID: "com.example.app")

        let commands = await mock.recordedCommands()
        // devicectl has no bundle-ID terminate, so the PID lookup is mandatory.
        XCTAssertEqual(commands[0], [
            "xcrun", "devicectl", "device", "info", "processes",
            "--device", "UDID-1", "--json-output", "-"
        ])
        XCTAssertEqual(commands[1], [
            "xcrun", "devicectl", "device", "process", "signal",
            "--device", "UDID-1", "--pid", "4321", "--signal", "SIGKILL"
        ])
    }

    func testTerminateIsIdempotentWhenAppIsNotRunning() async throws {
        let mock = MockShellExecutor(result: .init(
            exitCode: 0, stdout: #"{"result": {"runningProcesses": []}}"#, stderr: ""
        ))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.terminate(device: "UDID-1", appID: "com.example.app")

        let commands = await mock.recordedCommands()
        // Only the lookup ran — "already stopped" must not be an error, so teardown is safe to repeat.
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains("processes"))
    }

    func testTerminateIgnoresProcessesFromOtherBundles() async throws {
        let processes = """
        {
          "result": {
            "runningProcesses": [
              { "processIdentifier": 99, "executable": "file:///.../SomethingElse.app/SomethingElse" }
            ]
          }
        }
        """
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: processes, stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.terminate(device: "UDID-1", appID: "com.example.app")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands.count, 1, "must not signal a PID belonging to a different app")
    }

    // MARK: - Configuration

    func testLocationAndAppearanceCommands() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.setLocation(device: "UDID-1", latitude: 37.7749, longitude: -122.4194)
        try await runner.clearLocation(device: "UDID-1")
        try await runner.setAppearance(device: "UDID-1", appearance: .dark)

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], [
            "xcrun", "devicectl", "device", "simulate", "location", "coordinate",
            "--device", "UDID-1", "--latitude", "37.7749", "--longitude", "-122.4194"
        ])
        XCTAssertEqual(commands[1], [
            "xcrun", "devicectl", "device", "simulate", "location", "clear", "--device", "UDID-1"
        ])
        XCTAssertEqual(commands[2], [
            "xcrun", "devicectl", "device", "settings", "appearance", "--device", "UDID-1", "--mode", "dark"
        ])
    }

    func testOpenURLPassesPayloadURLToLaunch() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.openURL(device: "UDID-1", url: "https://example.com")

        let commands = await mock.recordedCommands()
        // devicectl has no standalone openurl; --payload-url on a launch is the documented equivalent.
        XCTAssertTrue(commands[0].contains("--payload-url"))
        XCTAssertTrue(commands[0].contains("https://example.com"))
    }

    // MARK: - Capture

    func testStartRecordingRequestsDestinationAndReturnsPID() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        let pid = try await runner.startRecording(device: "UDID-1", outputPath: "/tmp/out.mp4")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], [
            "xcrun", "devicectl", "device", "capture", "screen-record",
            "--device", "UDID-1", "--destination", "/tmp/out.mp4"
        ])
        XCTAssertGreaterThan(pid, 0)
    }

    func testScreenshotReadsBackWhatTheToolWroteThenCleansUp() async throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let writtenPaths = WrittenPathRecorder()

        // devicectl writes the image to --destination, so the fake does the same. This
        // exercises the read-back and cleanup that a fixed-output mock would skip.
        let context = ShellContext(executor: MockExecutor { command, _ in
            let arguments = command.arguments
            if let index = arguments.firstIndex(of: "--destination") {
                let path = arguments[index + 1]
                try pngBytes.write(to: URL(fileURLWithPath: path))
                await writtenPaths.record(path)
            }
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        })

        let data = try await DeviceCtlRunner(context: context).screenshot(device: "UDID-1")

        XCTAssertEqual(data, pngBytes)
        let paths = await writtenPaths.paths()
        XCTAssertEqual(paths.count, 1)
        // The temporary file must not be left behind after the bytes are read.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths[0]))
    }

    func testStopRecordingInterruptsTheProcessItStarted() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        let pid = try await runner.startRecording(device: "UDID-1", outputPath: "/tmp/out.mp4")
        try await runner.stopRecording(pid: pid)

        let commands = await mock.recordedCommands()
        // The tracked process is interrupted directly, so no `kill` shell-out is needed.
        XCTAssertFalse(commands.contains { $0.first == "kill" })
    }

    func testStopRecordingFallsBackToKillForAnUntrackedPID() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = DeviceCtlRunner(context: mock.context)

        try await runner.stopRecording(pid: 31337)

        let commands = await mock.recordedCommands()
        // SIGINT, not SIGKILL — SIGKILL would leave the .mp4 truncated.
        XCTAssertEqual(commands, [["kill", "-INT", "31337"]])
    }

    // MARK: - Error Mapping

    func testNonZeroExitIsMappedToProcessRunnerError() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 3, stdout: "", stderr: "device not found"))
        let runner = DeviceCtlRunner(context: mock.context)

        do {
            _ = try await runner.listDevices()
            XCTFail("Expected a non-zero exit to throw")
        } catch let error as ProcessRunnerError {
            guard case let .nonZeroExit(command, exitCode, stderr) = error else {
                return XCTFail("Expected nonZeroExit, got \(error)")
            }
            XCTAssertTrue(command.hasPrefix("xcrun devicectl list devices"))
            XCTAssertEqual(exitCode, 3)
            XCTAssertEqual(stderr, "device not found")
        }
    }
}

/// Records destination paths the fake devicectl wrote to, so tests can assert cleanup.
private actor WrittenPathRecorder {
    private var recorded: [String] = []

    func record(_ path: String) {
        recorded.append(path)
    }

    func paths() -> [String] {
        recorded
    }
}
