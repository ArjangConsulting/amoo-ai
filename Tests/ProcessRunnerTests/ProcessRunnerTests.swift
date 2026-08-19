import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testSystemRunnerExecutesCommand() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "hello", stderr: ""))
        let runner = SystemProcessRunner(context: mock.context)
        let result = try await runner.run(["printf", "hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands, [["printf", "hello"]])
    }

    func testSystemRunnerRejectsEmptyCommand() async throws {
        let runner = SystemProcessRunner()
        do {
            _ = try await runner.run([])
            XCTFail("Expected empty command to fail")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(error, .emptyCommand)
        }
    }

    func testSimctlRunnerPrefixesCommand() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "{}", stderr: ""))
        let runner = SimctlRunner(context: mock.context)

        _ = try await runner.run(["list", "devices", "available", "-j"])

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands, [["xcrun", "simctl", "list", "devices", "available", "-j"]])
    }

    func testSimctlRunnerAppLifecycle() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = SimctlRunner(context: mock.context)

        try await runner.install(device: "UDID-123", appPath: "/tmp/App.app")
        try await runner.launch(device: "UDID-123", appID: "com.example.app")
        try await runner.terminate(device: "UDID-123", appID: "com.example.app")
        try await runner.uninstall(device: "UDID-123", appID: "com.example.app")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["xcrun", "simctl", "install", "UDID-123", "/tmp/App.app"])
        XCTAssertEqual(commands[1], ["xcrun", "simctl", "launch", "UDID-123", "com.example.app"])
        XCTAssertEqual(commands[2], ["xcrun", "simctl", "terminate", "UDID-123", "com.example.app"])
        XCTAssertEqual(commands[3], ["xcrun", "simctl", "uninstall", "UDID-123", "com.example.app"])
    }

    func testSimctlRunnerListAndInspectionHelpers() async throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.example.first</key>
            <dict/>
            <key>com.example.second</key>
            <dict/>
        </dict>
        </plist>
        """
        let mock = MockShellExecutor(results: [
            .init(exitCode: 0, stdout: "devices-json", stderr: ""),
            .init(exitCode: 0, stdout: "app-list", stderr: ""),
            .init(exitCode: 0, stdout: plist, stderr: "")
        ])
        let runner = SimctlRunner(context: mock.context)

        let devices = try await runner.listDevices()
        let apps = try await runner.listApps(device: "booted")
        let appIDs = try await runner.listInstalledAppIDs(device: "booted")

        XCTAssertEqual(devices, "devices-json")
        XCTAssertEqual(apps, "app-list")
        XCTAssertEqual(Set(appIDs), ["com.example.first", "com.example.second"])

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["xcrun", "simctl", "list", "devices", "available", "--json"])
        XCTAssertEqual(commands[1], ["xcrun", "simctl", "listapps", "booted"])
        XCTAssertEqual(commands[2], ["xcrun", "simctl", "listapps", "booted"])
    }

    func testSimctlRunnerReturnsEmptyInstalledAppIDsForInvalidPlist() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "not-a-plist", stderr: ""))
        let runner = SimctlRunner(context: mock.context)

        let appIDs = try await runner.listInstalledAppIDs(device: "booted")

        XCTAssertEqual(appIDs, [])
    }

    func testSimctlRunnerConfiguration() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = SimctlRunner(context: mock.context)

        try await runner.setPermission(
            device: "booted", action: "grant", permission: "camera", appID: "com.example"
        )
        try await runner.setLocation(device: "booted", latitude: 37.77, longitude: -122.42)
        try await runner.clearLocation(device: "booted")
        try await runner.setAppearance(device: "booted", appearance: .dark)
        try await runner.openURL(device: "booted", url: "myapp://test")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(
            commands[0], ["xcrun", "simctl", "privacy", "booted", "grant", "camera", "com.example"]
        )
        XCTAssertEqual(commands[1], ["xcrun", "simctl", "location", "booted", "set", "37.77,-122.42"])
        XCTAssertEqual(commands[2], ["xcrun", "simctl", "location", "booted", "clear"])
        XCTAssertEqual(commands[3], ["xcrun", "simctl", "ui", "booted", "appearance", "dark"])
        XCTAssertEqual(commands[4], ["xcrun", "simctl", "openurl", "booted", "myapp://test"])
    }

    func testADBRunnerPrefixesAndHelpers() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(context: mock.context)

        try await runner.startServer()
        try await runner.killEmulator(serial: "emulator-5554")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "start-server"])
        XCTAssertEqual(commands[1], ["adb", "-s", "emulator-5554", "emu", "kill"])
    }

    func testADBRunnerListHelpersAndURLHandling() async throws {
        let mock = MockShellExecutor(results: [
            .init(exitCode: 0, stdout: "device-list", stderr: ""),
            .init(exitCode: 0, stdout: "package:com.example\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])
        let runner = ADBRunner(context: mock.context)

        let devices = try await runner.listDevices()
        let packages = try await runner.listPackages(serial: "emulator-5554")
        try await runner.openURL(serial: "emulator-5554", url: "myapp://details")

        XCTAssertEqual(devices, "device-list")
        XCTAssertEqual(packages, "package:com.example\n")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "devices", "-l"])
        XCTAssertEqual(commands[1], ["adb", "-s", "emulator-5554", "shell", "pm", "list", "packages"])
        XCTAssertEqual(
            commands[2],
            [
                "adb", "-s", "emulator-5554", "shell", "am", "start", "-a", "android.intent.action.VIEW",
                "-d", "myapp://details"
            ]
        )
    }

    func testADBRunnerLaunchFallsBackWhenResolveActivityFails() async throws {
        let mock = MockShellExecutor(results: [
            .init(exitCode: 1, stdout: "", stderr: "missing"),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])
        let runner = ADBRunner(context: mock.context)

        try await runner.launch(
            serial: "emulator-5554", appID: "com.example.app", arguments: ["foo", "bar"]
        )

        let commands = await mock.recordedCommands()
        XCTAssertEqual(
            commands[0],
            [
                "adb", "-s", "emulator-5554", "shell", "cmd", "package", "resolve-activity", "--brief",
                "com.example.app"
            ]
        )
        XCTAssertEqual(
            commands[1],
            [
                "adb", "-s", "emulator-5554", "shell", "am", "start", "-n", "com.example.app/.MainActivity",
                "--es", "arg", "foo",
                "--es", "arg", "bar"
            ]
        )
    }

    func testADBRunnerAppLifecycle() async throws {
        let mock = MockShellExecutor(results: [
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "com.example.app/.RealLauncherActivity\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "Success", stderr: "")
        ])
        let runner = ADBRunner(context: mock.context)

        try await runner.install(serial: "emulator-5554", apkPath: "/tmp/app.apk")
        try await runner.launch(serial: nil, appID: "com.example.app")
        try await runner.terminate(serial: nil, appID: "com.example.app")
        try await runner.uninstall(serial: nil, appID: "com.example.app")
        try await runner.clearAppData(serial: "emulator-5554", appID: "com.example.app")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "-s", "emulator-5554", "install", "-r", "/tmp/app.apk"])
        XCTAssertEqual(
            commands[1],
            ["adb", "shell", "cmd", "package", "resolve-activity", "--brief", "com.example.app"]
        )
        XCTAssertEqual(
            commands[2], ["adb", "shell", "am", "start", "-n", "com.example.app/.RealLauncherActivity"]
        )
        XCTAssertEqual(commands[3], ["adb", "shell", "am", "force-stop", "com.example.app"])
        XCTAssertEqual(commands[4], ["adb", "uninstall", "com.example.app"])
        XCTAssertEqual(
            commands[5],
            ["adb", "-s", "emulator-5554", "shell", "pm", "clear", "com.example.app"]
        )
    }

    func testGradleProjectBuilderUsesShipItGradleKit() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "BUILD SUCCESSFUL", stderr: ""))
        let builder = GradleProjectBuilder(context: mock.context)

        try await builder.assembleDebug(projectDirectory: "/tmp/project", module: "androidApp")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(
            commands,
            [["gradle", "--no-daemon", ":androidApp:assembleDebug"]]
        )
    }

    func testADBRunnerPermissions() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(context: mock.context)

        try await runner.grantPermission(
            serial: nil, appID: "com.example", permission: "android.permission.CAMERA"
        )
        try await runner.revokePermission(
            serial: nil, appID: "com.example", permission: "android.permission.CAMERA"
        )

        let commands = await mock.recordedCommands()
        XCTAssertEqual(
            commands[0], ["adb", "shell", "pm", "grant", "com.example", "android.permission.CAMERA"]
        )
        XCTAssertEqual(
            commands[1], ["adb", "shell", "pm", "revoke", "com.example", "android.permission.CAMERA"]
        )
    }

    func testADBRunnerPortForwarding() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(context: mock.context)

        try await runner.forwardPort(serial: nil, localPort: 22088, remotePort: 22088)
        try await runner.removeForward(serial: nil, localPort: 22088)

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "forward", "tcp:22088", "tcp:22088"])
        XCTAssertEqual(commands[1], ["adb", "forward", "--remove", "tcp:22088"])
    }

    func testSimctlRunnerPropagatesNonZeroExit() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 1, stdout: "", stderr: "failed"))
        let runner = SimctlRunner(context: mock.context)

        do {
            _ = try await runner.run(["list"])
            XCTFail("Expected non-zero exit to throw")
        } catch let error as ProcessRunnerError {
            switch error {
            case let .nonZeroExit(command, exitCode, stderr):
                XCTAssertEqual(command, "xcrun simctl list")
                XCTAssertEqual(exitCode, 1)
                XCTAssertEqual(stderr, "failed")
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }
}

final class MockShellExecutor: @unchecked Sendable {
    private let recorder: ShellCommandRecorder
    let context: ShellContext

    init(result: ProcessResult) {
        let recorder = ShellCommandRecorder(results: [result])
        self.recorder = recorder
        context = ShellContext(
            executor: MockExecutor { [recorder] command, _ in
                try await recorder.execute(command)
            }
        )
    }

    init(results: [ProcessResult]) {
        let recorder = ShellCommandRecorder(results: results)
        self.recorder = recorder
        context = ShellContext(
            executor: MockExecutor { [recorder] command, _ in
                try await recorder.execute(command)
            }
        )
    }

    func recordedCommands() async -> [[String]] {
        await recorder.recordedCommands()
    }
}

actor ShellCommandRecorder {
    private var commands: [[String]] = []
    private var results: [ShellOutput]

    init(results: [ProcessResult]) {
        self.results = results.map {
            ShellOutput(stdout: $0.stdout, stderr: $0.stderr, exitCode: $0.exitCode)
        }
    }

    func execute(_ command: Command) async throws -> ShellOutput {
        commands.append([command.executableName] + command.arguments)
        if results.count > 1 {
            return results.removeFirst()
        }
        return results.first ?? .init(stdout: "", stderr: "", exitCode: 0)
    }

    func recordedCommands() -> [[String]] {
        commands
    }
}
