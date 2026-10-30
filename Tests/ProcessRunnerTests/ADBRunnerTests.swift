import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import TestCommons
import XCTest

/// `ADBRunner` delegates to MobileDevices' `AndroidDeviceManager`; these pin the argv and error
/// contract Amoo's callers rely on.
final class ADBRunnerTests: XCTestCase {
    func testADBRunnerPrefixesAndHelpers() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(context: mock.context, emulatorDiscoveryDirectories: [])

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

    /// A failed resolve used to guess `<appID>/.MainActivity`, which is wrong whenever the launcher
    /// class lives outside the applicationId package (flavors, applicationIdSuffix). Report it instead.
    func testADBRunnerLaunchFailsClearlyWhenNoLauncherActivityResolves() async throws {
        let mock = MockShellExecutor(results: [
            .init(exitCode: 0, stdout: "No activity found\n", stderr: "")
        ])
        let runner = ADBRunner(context: mock.context)

        do {
            try await runner.launch(serial: "emulator-5554", appID: "com.example.app", arguments: ["foo", "bar"])
            XCTFail("expected a launcher-resolution failure")
        } catch {
            XCTAssertTrue("\(error)".contains("No launchable activity for com.example.app"), "\(error)")
        }

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands.count, 1, "no `am start` against a guessed component")
        XCTAssertEqual(
            commands[0],
            [
                "adb", "-s", "emulator-5554", "shell", "cmd", "package", "resolve-activity", "--brief",
                "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER",
                "com.example.app"
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
        try await runner.launch(serial: "emulator-5554", appID: "com.example.app")
        try await runner.terminate(serial: "emulator-5554", appID: "com.example.app")
        try await runner.uninstall(serial: "emulator-5554", appID: "com.example.app")
        try await runner.clearAppData(serial: "emulator-5554", appID: "com.example.app")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "-s", "emulator-5554", "install", "-r", "/tmp/app.apk"])
        XCTAssertEqual(
            commands[1],
            [
                "adb", "-s", "emulator-5554", "shell", "cmd", "package", "resolve-activity", "--brief",
                "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER",
                "com.example.app"
            ]
        )
        XCTAssertEqual(
            commands[2],
            ["adb", "-s", "emulator-5554", "shell", "am", "start", "-n", "com.example.app/.RealLauncherActivity"]
        )
        XCTAssertEqual(
            commands[3], ["adb", "-s", "emulator-5554", "shell", "am", "force-stop", "com.example.app"]
        )
        XCTAssertEqual(commands[4], ["adb", "-s", "emulator-5554", "uninstall", "com.example.app"])
        XCTAssertEqual(
            commands[5],
            ["adb", "-s", "emulator-5554", "shell", "pm clear com.example.app"]
        )
    }

    /// `adb` without `-s` picks the only attached device; `AndroidDeviceManager` needs a serial, so
    /// the runner resolves that default itself.
    func testADBRunnerResolvesTheOnlyDeviceWhenNoSerialIsGiven() async throws {
        let mock = MockShellExecutor(results: [
            .init(exitCode: 0, stdout: "List of devices attached\nemulator-5554 device model:sdk\n", stderr: ""),
            .init(exitCode: 0, stdout: "", stderr: "")
        ])

        try await ADBRunner(context: mock.context).terminate(serial: nil, appID: "com.example.app")

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "devices", "-l"])
        XCTAssertEqual(
            commands[1], ["adb", "-s", "emulator-5554", "shell", "am", "force-stop", "com.example.app"]
        )
    }

    func testADBRunnerRefusesAnAmbiguousDefaultDevice() async throws {
        let mock = MockShellExecutor(result: .init(
            exitCode: 0,
            stdout: "List of devices attached\nemulator-5554 device\nemulator-5556 device\n",
            stderr: ""
        ))

        do {
            try await ADBRunner(context: mock.context).uninstall(serial: nil, appID: "com.example.app")
            XCTFail("Expected an ambiguous default device to fail")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(
                error,
                .nonZeroExit(command: "adb", exitCode: 1, stderr: "adb: more than one device/emulator")
            )
        }
        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands.count, 1, "no mutation may run without a resolved device")
    }

    func testADBRunnerPermissions() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(context: mock.context)

        try await runner.grantPermission(
            serial: "emulator-5554", appID: "com.example", permission: "android.permission.CAMERA"
        )
        try await runner.revokePermission(
            serial: "emulator-5554", appID: "com.example", permission: "android.permission.CAMERA"
        )

        let commands = await mock.recordedCommands()
        XCTAssertEqual(
            commands[0],
            ["adb", "-s", "emulator-5554", "shell", "pm", "grant", "com.example", "android.permission.CAMERA"]
        )
        XCTAssertEqual(
            commands[1],
            ["adb", "-s", "emulator-5554", "shell", "pm", "revoke", "com.example", "android.permission.CAMERA"]
        )
    }

    func testADBRunnerPortForwarding() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = ADBRunner(context: mock.context)

        try await runner.forwardPort(serial: "emulator-5554", localPort: 22088, remotePort: 22088)
        try await runner.removeForward(serial: "emulator-5554", localPort: 22088)

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], ["adb", "-s", "emulator-5554", "forward", "tcp:22088", "tcp:22088"])
        XCTAssertEqual(commands[1], ["adb", "-s", "emulator-5554", "forward", "--remove", "tcp:22088"])
    }
}
