import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

actor MockSessionBootstrapper: SessionBootstrapper {
    private var devices: [DeviceInfo] = []
    private(set) var lastDriver: MockDriver?
    private(set) var lastLaunchArguments: [String] = []
    private(set) var lastLaunchEnvironment: [String: String] = [:]

    func setDevices(_ values: [DeviceInfo]) {
        devices = values
    }

    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
        let driver = MockDriver()
        lastDriver = driver
        lastLaunchArguments = request.arguments
        lastLaunchEnvironment = request.environment
        return BootstrapResult(
            driver: driver,
            deviceID: "mock-\(request.platform.rawValue)",
            platform: request.platform,
            cleanup: {}
        )
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        devices
    }
}

actor AppListMockDriver: PlatformDriver {
    func listApps() async throws -> [AppInfo] {
        [
            AppInfo(appID: "com.example.one", name: "One", version: "1.0"),
            AppInfo(appID: "com.example.two", name: "Two", version: nil)
        ]
    }
}

actor LaunchTrackingDriver: PlatformDriver {
    struct LaunchCall: Sendable, Equatable {
        let appID: String
        let arguments: [String]
        let environment: [String: String]
    }

    private(set) var launchCalls: [LaunchCall] = []

    func launchApp(appID: String, arguments: [String], environment: [String: String]) async throws {
        launchCalls.append(LaunchCall(appID: appID, arguments: arguments, environment: environment))
    }
}

actor SetTextTrackingDriver: PlatformDriver {
    struct SetTextCall: Sendable {
        let selector: ElementSelector
        let text: String
    }

    private(set) var setTextCalls: [SetTextCall] = []
    private var value = ""

    func setText(_ selector: ElementSelector, text: String) async throws {
        setTextCalls.append(SetTextCall(selector: selector, text: text))
        value = text
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        [ElementInfo(id: "email-field", label: "Email", value: value, type: .textField)]
    }
}

/// A text field that ignores `setText` and keeps reporting whatever it already held.
actor StubbornFieldDriver: PlatformDriver {
    private let existingValue: String

    init(existingValue: String) {
        self.existingValue = existingValue
    }

    func setText(_: ElementSelector, text _: String) async throws {}

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        [ElementInfo(id: "email-field", label: "Email", value: existingValue, type: .textField)]
    }
}

/// Reports the previous app as frontmost for the first few reads, the way a device does while the
/// launch animation is still running.
actor SettlingLaunchDriver: PlatformDriver {
    private let settleAfterReads: Int
    private let targetAppID: String
    private var reads = 0

    init(settleAfterReads: Int, targetAppID: String) {
        self.settleAfterReads = settleAfterReads
        self.targetAppID = targetAppID
    }

    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {}

    func currentApp() async throws -> CurrentApp {
        reads += 1
        let bundleID = reads > settleAfterReads ? targetAppID : "com.other"
        return CurrentApp(bundleID: bundleID, targetBundleID: targetAppID)
    }

    func appState(appID _: String) async throws -> AppState {
        reads > settleAfterReads ? .running : .notRunning
    }
}

actor NavigationMockDriver: PlatformDriver {
    private let elements: [ElementInfo]
    private let summary: String
    private(set) var tappedSelectors: [ElementSelector] = []
    private var currentSummary: String

    init(
        elements: [ElementInfo] = [
            ElementInfo(id: "submit_btn", label: "Submit", type: .button),
            ElementInfo(id: "cancel_btn", label: "Cancel", type: .button)
        ],
        summary: String = "Home screen"
    ) {
        self.elements = elements
        self.summary = summary
        currentSummary = summary
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        elements
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        elements
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: currentSummary)
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        elements
    }

    func tapElement(_ selector: ElementSelector) async throws {
        tappedSelectors.append(selector)
        currentSummary = "After tap: \(selector.label ?? selector.id ?? "?")"
    }
}
