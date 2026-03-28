import Foundation
import MobileTestingCore
import ProcessRunner
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testSystemRunnerExecutesCommand() async throws {
        let runner = SystemProcessRunner()
        let result = try await runner.run(["/bin/sh", "-c", "printf 'hello'"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello")
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
        let mock = MockProcessRunner(result: .init(exitCode: 0, stdout: "{}", stderr: ""))
        let runner = SimctlRunner(processRunner: mock)

        _ = try await runner.run(["list", "devices", "available", "-j"])

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands, [["xcrun", "simctl", "list", "devices", "available", "-j"]])
    }

    func testSimctlRunnerAppLifecycle() async throws {
        let mock = MockProcessRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = SimctlRunner(processRunner: mock)

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
        let mock = MockProcessRunner(results: [
            .init(exitCode: 0, stdout: "devices-json", stderr: ""),
            .init(exitCode: 0, stdout: "app-list", stderr: ""),
            .init(exitCode: 0, stdout: plist, stderr: "")
        ])
        let runner = SimctlRunner(processRunner: mock)

        let devices = try await runner.listDevices()
        let apps = try await runner.listApps(device: "booted")
        let appIDs = try await runner.listInstalledAppIDs(device: "booted")

        XCTAssertEqual(devices, "devices-json")
        XCTAssertEqual(apps, "app-list")
        XCTAssertEqual(Set(appIDs), ["com.example.first", "com.example.second"])

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["xcrun", "simctl", "list", "devices", "available", "-j"])
        XCTAssertEqual(commands[1], ["xcrun", "simctl", "listapps", "booted"])
        XCTAssertEqual(commands[2], ["xcrun", "simctl", "listapps", "booted"])
    }

    func testSimctlRunnerReturnsEmptyInstalledAppIDsForInvalidPlist() async throws {
        let mock = MockProcessRunner(result: .init(exitCode: 0, stdout: "not-a-plist", stderr: ""))
        let runner = SimctlRunner(processRunner: mock)

        let appIDs = try await runner.listInstalledAppIDs(device: "booted")

        XCTAssertEqual(appIDs, [])
    }

    func testSimctlRunnerConfiguration() async throws {
        let mock = MockProcessRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = SimctlRunner(processRunner: mock)

        try await runner.setPermission(device: "booted", action: "grant", permission: "camera", appID: "com.example")
        try await runner.setLocation(device: "booted", latitude: 37.77, longitude: -122.42)
        try await runner.clearLocation(device: "booted")
        try await runner.setAppearance(device: "booted", appearance: .dark)
        try await runner.openURL(device: "booted", url: "myapp://test")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["xcrun", "simctl", "privacy", "booted", "grant", "camera", "com.example"])
        XCTAssertEqual(commands[1], ["xcrun", "simctl", "location", "booted", "set", "37.77,-122.42"])
        XCTAssertEqual(commands[2], ["xcrun", "simctl", "location", "booted", "clear"])
        XCTAssertEqual(commands[3], ["xcrun", "simctl", "ui", "booted", "appearance", "dark"])
        XCTAssertEqual(commands[4], ["xcrun", "simctl", "openurl", "booted", "myapp://test"])
    }

    func testADBRunnerPrefixesAndHelpers() async throws {
        let mock = MockProcessRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(processRunner: mock)

        try await runner.startServer()
        try await runner.killEmulator(serial: "emulator-5554")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "start-server"])
        XCTAssertEqual(commands[1], ["adb", "-s", "emulator-5554", "emu", "kill"])
    }

    func testADBRunnerListHelpersAndURLHandling() async throws {
        let mock = MockProcessRunner(results: [
            .init(exitCode: 0, stdout: "device-list", stderr: ""),
            .init(exitCode: 0, stdout: "package:com.example\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])
        let runner = ADBRunner(processRunner: mock)

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
            ["adb", "-s", "emulator-5554", "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "myapp://details"]
        )
    }

    func testADBRunnerLaunchFallsBackWhenResolveActivityFails() async throws {
        let mock = MockProcessRunner(results: [
            .init(exitCode: 1, stdout: "", stderr: "missing"),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])
        let runner = ADBRunner(processRunner: mock)

        try await runner.launch(serial: "emulator-5554", appID: "com.example.app", arguments: ["foo", "bar"])

        let commands = await mock.recordedCommands()
        XCTAssertEqual(
            commands[0],
            ["adb", "-s", "emulator-5554", "shell", "cmd", "package", "resolve-activity", "--brief", "com.example.app"]
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
        let mock = MockProcessRunner(results: [
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "com.example.app/.RealLauncherActivity\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])
        let runner = ADBRunner(processRunner: mock)

        try await runner.install(serial: "emulator-5554", apkPath: "/tmp/app.apk")
        try await runner.launch(serial: nil, appID: "com.example.app")
        try await runner.terminate(serial: nil, appID: "com.example.app")
        try await runner.uninstall(serial: nil, appID: "com.example.app")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "-s", "emulator-5554", "install", "-r", "/tmp/app.apk"])
        XCTAssertEqual(
            commands[1],
            ["adb", "shell", "cmd", "package", "resolve-activity", "--brief", "com.example.app"]
        )
        XCTAssertEqual(commands[2], ["adb", "shell", "am", "start", "-n", "com.example.app/.RealLauncherActivity"])
        XCTAssertEqual(commands[3], ["adb", "shell", "am", "force-stop", "com.example.app"])
        XCTAssertEqual(commands[4], ["adb", "uninstall", "com.example.app"])
    }

    func testADBRunnerPermissions() async throws {
        let mock = MockProcessRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(processRunner: mock)

        try await runner.grantPermission(serial: nil, appID: "com.example", permission: "android.permission.CAMERA")
        try await runner.revokePermission(serial: nil, appID: "com.example", permission: "android.permission.CAMERA")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "shell", "pm", "grant", "com.example", "android.permission.CAMERA"])
        XCTAssertEqual(commands[1], ["adb", "shell", "pm", "revoke", "com.example", "android.permission.CAMERA"])
    }

    func testADBRunnerPortForwarding() async throws {
        let mock = MockProcessRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(processRunner: mock)

        try await runner.forwardPort(serial: nil, localPort: 22088, remotePort: 22088)
        try await runner.removeForward(serial: nil, localPort: 22088)

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "forward", "tcp:22088", "tcp:22088"])
        XCTAssertEqual(commands[1], ["adb", "forward", "--remove", "tcp:22088"])
    }

    func testSimctlRunnerPropagatesNonZeroExit() async throws {
        let mock = MockProcessRunner(result: .init(exitCode: 1, stdout: "", stderr: "failed"))
        let runner = SimctlRunner(processRunner: mock)

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

private actor MockProcessRunner: ProcessRunner {
    private var commands: [[String]] = []
    private var results: [ProcessResult]

    init(result: ProcessResult) {
        results = [result]
    }

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ arguments: [String]) async throws -> ProcessResult {
        commands.append(arguments)
        if results.count > 1 {
            return results.removeFirst()
        }
        return results.first ?? .init(exitCode: 0, stdout: "", stderr: "")
    }

    func recordedCommands() -> [[String]] {
        commands
    }
}
