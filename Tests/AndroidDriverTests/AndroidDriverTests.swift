import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import ProcessRunner
import XCTest

final class AndroidDriverTests: XCTestCase {
    func testTapDelegatesToCompanion() async throws {
        let driver = AndroidDriver(companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)))
        try await driver.tap(at: Point(x: 8, y: 16))
        let elements = try await driver.findElements(.init(label: "Continue"))
        XCTAssertEqual(elements.first?.label, "Continue")
    }

    func testBootAndShutdownExecute() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)),
            adb: adb
        )
        try await driver.boot()
        try await driver.shutdown()

        let calls = await adb.calls()
        XCTAssertEqual(calls.startServerCalls, 1)
        XCTAssertEqual(calls.killCalls, ["emulator-5554"])
    }

    func testBootLaunchesNamedAVDAndWaitsUntilAndroidReportsReady() async throws {
        let adb = MockADBRunner()
        await adb.setDeviceOutputs([
            "List of devices attached\n",
            "List of devices attached\nemulator-5554\tdevice\n"
        ])
        let emulator = MockEmulatorRunner()
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: emulator,
            serial: "Medium_Phone_API_35"
        )

        try await driver.boot()

        let launches = await emulator.launches
        XCTAssertEqual(launches, ["Medium_Phone_API_35:5554"])
        let deviceInfo = try await driver.deviceInfo()
        XCTAssertEqual(deviceInfo.id, "emulator-5554")
    }

    func testContextAndCaptureAndPermission() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)),
            adb: adb
        )

        let hierarchy = try await driver.getViewHierarchy()
        let context = try await driver.getScreenContext()
        let screenshot = try await driver.takeScreenshot(format: .png)

        XCTAssertEqual(hierarchy.id, "root")
        XCTAssertEqual(context.summary, "Empty screen context")
        XCTAssertEqual(screenshot.bytes, [0xAB])
    }

    func testAppLifecycleDelegatesToADB() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)),
            adb: adb
        )

        try await driver.installApp(path: "/tmp/app.apk")
        try await driver.launchApp(appID: "com.example.app")
        try await driver.terminateApp(appID: "com.example.app")
        try await driver.uninstallApp(appID: "com.example.app")

        let appCalls = await adb.appCalls()
        XCTAssertEqual(appCalls, [
            "install:com.example.app:/tmp/app.apk",
            "launchResetting:com.example.app",
            "terminate:com.example.app",
            "uninstall:com.example.app"
        ])
    }

    func testPermissionDelegatesToADB() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)),
            adb: adb
        )

        try await driver.setPermission(.init(
            appID: "com.example",
            permission: "android.permission.CAMERA",
            granted: true
        ))
        try await driver.setPermission(.init(
            appID: "com.example",
            permission: "android.permission.CAMERA",
            granted: false
        ))

        let permCalls = await adb.permissionCalls()
        XCTAssertEqual(permCalls, [
            "grant:com.example:android.permission.CAMERA",
            "revoke:com.example:android.permission.CAMERA"
        ])
    }

    func testRecordingPullsArtifactAndReturnsLocalPath() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)

        let session = try await driver.startRecording()
        let outputPath = try await driver.stopRecording(sessionID: session.id)

        let recordingCalls = await adb.recordingCalls()
        XCTAssertEqual(recordingCalls.started.count, 1)
        XCTAssertEqual(recordingCalls.stopped, 1)
        XCTAssertTrue(recordingCalls.pulls.first?.remotePath.hasSuffix(".mp4") == true)
        XCTAssertTrue(outputPath.hasSuffix(".mp4"))
    }

    func testDeviceInfoUsesSerialWhenProvided() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")

        let info = try await driver.deviceInfo()
        let listDevicesCallCount = await adb.listDevicesCallCount()

        XCTAssertEqual(info.id, "emulator-5554")
        XCTAssertEqual(info.name, "emulator-5554")
        XCTAssertEqual(info.platform, .android)
        XCTAssertEqual(info.osVersion, "unknown")
        XCTAssertEqual(info.state, .booted)
        XCTAssertEqual(listDevicesCallCount, 1)
    }

    func testListAppsFiltersBlankPackageEntries() async throws {
        let adb = MockADBRunner()
        await adb.setPackageList("package:com.example.one\n\npackage: com.example.two \npackage:\n")
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)

        let apps = try await driver.listApps()

        XCTAssertEqual(apps, [AppInfo(appID: "com.example.one"), AppInfo(appID: "com.example.two")])
    }

    func testDelegatesRemainingCompanionAndADBOperations() async throws {
        let adb = MockADBRunner()
        let companion = MockCompanionClient()
        let driver = AndroidDriver(companion: companion, adb: adb, serial: "emulator-5554")

        try await driver.doubleTap(at: Point(x: 1, y: 2))
        try await driver.longPress(at: Point(x: 3, y: 4), duration: .defaultLongPress)
        try await driver.tapElement(.init(id: "login"))
        try await driver.swipe(from: Point(x: 0, y: 0), to: Point(x: 50, y: 100), duration: .defaultSwipe)
        try await driver.scroll(direction: .down, distance: 120)
        try await driver.typeText("hello")
        try await driver.clearText(characterCount: 3)
        try await driver.pressBack()
        try await driver.pressHome()
        try await driver.openURL("myapp://details")

        let actionCalls = await companion.actionCalls()
        let rawCommands = await adb.rawCommands()
        let openURLCalls = await adb.openURLCalls()

        XCTAssertEqual(actionCalls.doubleTapPoints, [Point(x: 1, y: 2)])
        XCTAssertEqual(actionCalls.longPresses.count, 1)
        XCTAssertEqual(actionCalls.tappedElements, [.init(id: "login")])
        XCTAssertEqual(actionCalls.swipes.count, 1)
        XCTAssertEqual(actionCalls.scrolls.count, 1)
        XCTAssertEqual(actionCalls.typedTexts, ["hello"])
        XCTAssertEqual(actionCalls.clearTextRequests, [3])
        XCTAssertEqual(actionCalls.pressBackCount, 1)
        XCTAssertEqual(openURLCalls, ["myapp://details"])
        XCTAssertEqual(rawCommands, [["-s", "emulator-5554", "shell", "input", "keyevent", "KEYCODE_HOME"]])
    }

    func testRecordingErrorsForSecondSessionAndUnknownSession() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)

        _ = try await driver.startRecording()

        do {
            _ = try await driver.startRecording()
            XCTFail("Expected commandFailed error")
        } catch let error as AmooError {
            XCTAssertEqual(
                error,
                .commandFailed(
                    command: "startRecording",
                    output: "Only one active Android recording is supported per driver."
                )
            )
        }

        do {
            _ = try await driver.stopRecording(sessionID: "missing")
            XCTFail("Expected commandFailed error")
        } catch let error as AmooError {
            XCTAssertEqual(
                error,
                .commandFailed(command: "stopRecording", output: "No active recording with session ID: missing")
            )
        }
    }

    func testElementQueriesAndWaitsUseCompanion() async throws {
        let adb = MockADBRunner()
        let companion = MockCompanionClient()
        await companion.setFindElementsResponses([
            [ElementInfo(id: "login", label: "Login")],
            [ElementInfo(id: "spinner", label: "Loading")],
            []
        ])
        let driver = AndroidDriver(companion: companion, adb: adb)

        let exists = try await driver.elementExists(.init(id: "login"))
        try await driver.waitForElement(.init(id: "login"), timeout: .defaultSwipe)
        try await driver.waitForElementToDisappear(.init(id: "spinner"), timeout: Duration(milliseconds: 250))

        let waitCalls = await companion.waitForElementCalls()
        XCTAssertTrue(exists)
        XCTAssertEqual(waitCalls.count, 1)
        XCTAssertEqual(waitCalls.first?.selector.id, "login")
    }

    func testWaitForElementToDisappearTimesOutWhenElementPersists() async throws {
        let companion = MockCompanionClient()
        await companion.setFindElementsResponses([[ElementInfo(id: "spinner", label: "Loading")]])
        let driver = AndroidDriver(companion: companion, adb: MockADBRunner())

        do {
            try await driver.waitForElementToDisappear(.init(id: "spinner"), timeout: Duration(milliseconds: 1))
            XCTFail("Expected timeout error")
        } catch let error as AmooError {
            XCTAssertEqual(error, .timeout(operation: "waitForElementToDisappear", duration: Duration(milliseconds: 1)))
        }
    }

    func testLocationAppearanceKeyboardAndAIContextPaths() async throws {
        let adb = MockADBRunner()
        let companion = MockCompanionClient()
        await companion.setKeyboardVisible(true)
        await companion.setInteractableElements([ElementInfo(id: "cta", label: "Continue")])
        await companion.setFindByDescriptionResults([ElementInfo(id: "settings", label: "Settings")])
        let driver = AndroidDriver(companion: companion, adb: adb, serial: "emulator-5554")

        try await driver.setLocation(latitude: 37.5, longitude: -122.2)
        try await driver.clearLocation()
        try await driver.setAppearance(.dark)
        try await driver.setAppearance(.light)

        let keyboardVisible = try await driver.isKeyboardVisible()
        let interactable = try await driver.getInteractableElements()
        let described = try await driver.findByDescription("settings")
        let appState = try await driver.appState(appID: "com.example")
        let commands = await adb.rawCommands()

        XCTAssertTrue(keyboardVisible)
        XCTAssertEqual(interactable, [ElementInfo(id: "cta", label: "Continue")])
        XCTAssertEqual(described, [ElementInfo(id: "settings", label: "Settings")])
        XCTAssertEqual(appState, .running)
        XCTAssertEqual(commands, [
            ["-s", "emulator-5554", "emu", "geo", "fix", "-122.2", "37.5"],
            ["-s", "emulator-5554", "emu", "geo", "fix", "0.0", "0.0"],
            ["-s", "emulator-5554", "shell", "cmd", "uimode", "night", "yes"],
            ["-s", "emulator-5554", "shell", "cmd", "uimode", "night", "no"],
            ["-s", "emulator-5554", "shell", "pidof", "com.example"]
        ])
    }

    /// `adb shell pidof <pkg>` exits non-zero when the package has no live process, and adb
    /// propagates that exit code — so "not running" arrives as a thrown error, not empty stdout.
    func testAppStateReportsNotRunningWhenPidofExitsNonZero() async throws {
        let adb = MockADBRunner()
        await adb.setFailingRawCommandSuffix(["shell", "pidof", "com.example.app"])
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")

        let installed = try await driver.appState(appID: "com.example.app")
        XCTAssertEqual(installed, .notRunning)
    }

    func testAppStateReportsNotInstalledWhenPackageIsAbsent() async throws {
        let adb = MockADBRunner()
        await adb.setFailingRawCommandSuffix(["shell", "pidof", "com.other.app"])
        await adb.setPackageList("package:com.example.app\n")
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")

        let state = try await driver.appState(appID: "com.other.app")
        XCTAssertEqual(state, .notInstalled)
    }

    func testSwipeDirectionDelegatesToCompanion() async throws {
        let companion = MockCompanionClient()
        let driver = AndroidDriver(companion: companion)
        try await driver.swipe(direction: .up, distance: 250, duration: Duration(milliseconds: 350))
        let swipes = await companion.swipeDirections
        XCTAssertEqual(swipes.count, 1)
        XCTAssertEqual(swipes[0].direction, .up)
        XCTAssertEqual(swipes[0].distance, 250)
        XCTAssertEqual(swipes[0].duration, Duration(milliseconds: 350))
        XCTAssertNil(swipes[0].element)
    }
}
