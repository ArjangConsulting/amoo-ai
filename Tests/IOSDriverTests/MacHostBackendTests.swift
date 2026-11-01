import AmooCore
import Foundation
import IOSDriver
import TestCommons
import XCTest

final class MacHostBackendTests: XCTestCase {
    func testThisMacIsAlwaysABootedMacOSDevice() async throws {
        let info = try await MacHostBackend(workspace: FakeMacWorkspace()).deviceInfo(device: "anything")

        XCTAssertEqual(info.id, MacHostBackend.deviceID)
        XCTAssertEqual(info.platform, .macos)
        XCTAssertEqual(info.state, .booted)
    }

    /// A build installed through the backend is the one launched, even when Launch Services would
    /// resolve the bundle id to another copy, and a running instance is quit first so the launch
    /// arguments reach a fresh process.
    func testLaunchOpensTheInstalledBuildAfterQuittingTheRunningOne() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let app = try makeApp(named: "Notes.app", bundleID: "com.example.notes", in: scratch)
        let elsewhere = URL(fileURLWithPath: "/Applications/Notes.app")
        let workspace = FakeMacWorkspace(resolved: ["com.example.notes": elsewhere])
        let backend = MacHostBackend(workspace: workspace)

        try await backend.installApp(device: "mac", path: app.path)
        try await backend.launchApp(
            device: "mac",
            appID: "com.example.notes",
            arguments: ["-reset"],
            environment: ["MODE": "test"]
        )

        XCTAssertEqual(workspace.calls, [
            "register:\(app.lastPathComponent)",
            "terminate:com.example.notes",
            "launch:\(app.lastPathComponent):-ApplePersistenceIgnoreState YES -reset:MODE=test"
        ])
    }

    func testLaunchFallsBackToLaunchServicesAndRefusesAnUnknownApp() async throws {
        let workspace = FakeMacWorkspace(resolved: ["com.example.mail": URL(fileURLWithPath: "/Applications/Mail.app")])
        let backend = MacHostBackend(workspace: workspace)

        try await backend.launchApp(device: "mac", appID: "com.example.mail", arguments: [], environment: [:])
        XCTAssertEqual(workspace.calls.last, "launch:Mail.app:-ApplePersistenceIgnoreState YES:")

        do {
            try await backend.launchApp(device: "mac", appID: "com.example.missing", arguments: [], environment: [:])
            XCTFail("Expected launching an app that is not installed to fail")
        } catch let error as AmooError {
            XCTAssertEqual(error, .appNotInstalled(appID: "com.example.missing"))
        }
    }

    /// amoo is driving the user's own machine: nothing that would change the Mac itself is attempted.
    func testOperationsThatWouldChangeTheMacAreRefused() async {
        let workspace = FakeMacWorkspace()
        let backend = MacHostBackend(workspace: workspace)
        let refusals: [(String, () async throws -> Void)] = [
            ("shutdown", { try await backend.shutdown(device: "mac") }),
            ("uninstall", { try await backend.uninstallApp(device: "mac", appID: "com.example.notes") }),
            ("location", { try await backend.setLocation(device: "mac", latitude: 1, longitude: 2) }),
            ("appearance", { try await backend.setAppearance(device: "mac", appearance: .dark) }),
            ("recording", { _ = try await backend.startRecording(device: "mac", outputPath: "/tmp/x.mov") })
        ]
        for (name, operation) in refusals {
            do {
                try await operation()
                XCTFail("\(name) should be refused")
            } catch let error as AmooError {
                guard case .unsupportedCapability = error else {
                    return XCTFail("\(name) failed with \(error), not as unsupported")
                }
            } catch {
                XCTFail("\(name) failed with \(error)")
            }
        }
        XCTAssertEqual(workspace.calls, [])
    }

    func testOpenURLNeedsAScheme() async throws {
        let workspace = FakeMacWorkspace()
        let backend = MacHostBackend(workspace: workspace)

        try await backend.openURL(device: "mac", url: "notes://note/1")
        XCTAssertEqual(workspace.calls, ["open:notes://note/1"])

        do {
            try await backend.openURL(device: "mac", url: "note 1")
            XCTFail("Expected a URL without a scheme to be rejected")
        } catch {}
    }

    /// The Mac has no host screenshot, so a failed companion screenshot must surface as itself
    /// rather than as the host's "not available" refusal, which hid the real cause.
    func testFailedCompanionScreenshotReportsTheCompanionError() async throws {
        let companion = MockCompanionClient()
        await companion.setScreenshotError(AmooError.companionNotConnected)
        let driver = IOSDriver(
            companion: companion,
            backend: MacHostBackend(workspace: FakeMacWorkspace()),
            deviceID: MacHostBackend.deviceID
        )

        do {
            _ = try await driver.takeScreenshot(format: .png)
            XCTFail("Expected the screenshot to fail")
        } catch let error as AmooError {
            XCTAssertEqual(error, .companionNotConnected)
        }
    }

    /// Behind the lock screen nothing can be found or driven, so the launch says so instead of
    /// starting a session that finds no window.
    func testLaunchIsRefusedWhileTheScreenIsLocked() async throws {
        let workspace = FakeMacWorkspace(
            resolved: ["com.example.mail": URL(fileURLWithPath: "/Applications/Mail.app")],
            locked: true
        )
        let backend = MacHostBackend(workspace: workspace)

        do {
            try await backend.launchApp(device: "mac", appID: "com.example.mail", arguments: [], environment: [:])
            XCTFail("Expected the launch to be refused")
        } catch {
            XCTAssertTrue(String(describing: error).contains("screen is locked"), String(describing: error))
        }
        XCTAssertEqual(workspace.calls, [])
    }

    /// A caller that chose how saved window state is handled keeps its choice.
    func testLaunchArgumentsIgnoreSavedWindowStateUnlessTheCallerChose() {
        XCTAssertEqual(MacHostBackend.launchArguments(["-x"]), ["-ApplePersistenceIgnoreState", "YES", "-x"])
        XCTAssertEqual(
            MacHostBackend.launchArguments(["-ApplePersistenceIgnoreState", "NO"]),
            ["-ApplePersistenceIgnoreState", "NO"]
        )
    }

    private func makeApp(named name: String, bundleID: String, in scratch: TemporaryDirectory) throws -> URL {
        let contents = scratch.url.appending(path: "\(name)/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL"],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appending(path: "Info.plist"))
        return scratch.url.appending(path: name)
    }
}

/// Records what the backend asked the Mac to do, without touching the desktop.
private final class FakeMacWorkspace: MacWorkspace, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let resolved: [String: URL]
    private let locked: Bool

    init(resolved: [String: URL] = [:], locked: Bool = false) {
        self.resolved = resolved
        self.locked = locked
    }

    func isScreenLocked() -> Bool {
        locked
    }

    var calls: [String] {
        lock.withLock { recorded }
    }

    private func record(_ call: String) {
        lock.withLock { recorded.append(call) }
    }

    func register(appAt url: URL) throws {
        record("register:\(url.lastPathComponent)")
    }

    func applicationURL(bundleID: String) -> URL? {
        resolved[bundleID]
    }

    func launch(appAt url: URL, arguments: [String], environment: [String: String]) async throws {
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        record("launch:\(url.lastPathComponent):\(arguments.joined(separator: " ")):\(env)")
    }

    func terminate(bundleID: String) async throws {
        record("terminate:\(bundleID)")
    }

    func runningApps() -> [AppInfo] {
        []
    }

    func open(_ url: URL) async throws {
        record("open:\(url.absoluteString)")
    }
}
