import AmooCore
@testable import AmooTools
import XCTest

/// A system prompt that comes up over a tap's result ("Save Password?" after a sign-in) hides the
/// element the tap's expectation waits for. The tap already landed, so it is never sent again.
final class SystemDialogExpectationTests: XCTestCase {
    private let signIn = [
        "id": "auth.sign_in", "expect_id": "account.header", "expect_timeout_ms": "300", "check_hittable": "false"
    ]

    func testAPromptOverTheResultIsAnsweredAndTheExpectationCheckedAgain() async {
        let driver = SignInDriver()
        var arguments = signIn
        arguments["dismiss_system_dialogs"] = "true"
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "tap_element", arguments: arguments)
        let fields = result.structuredContent?.objectValue
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(fields?["expected_effect_met"], .bool(true), result.content)
        XCTAssertNotNil(fields?["dismissed_dialog"])
        XCTAssertTrue(result.content.contains("the tap was not repeated"), result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, ["Sign in", "Not Now"], "the sign-in tap is sent once")
    }

    func testWithoutTheSwitchTheUnmetExpectationNamesThePrompt() async {
        let driver = SignInDriver()
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "tap_element", arguments: signIn)
        let fields = result.structuredContent?.objectValue
        XCTAssertEqual(fields?["expected_effect_met"], .bool(false), result.content)
        XCTAssertNotNil(fields?["blocking_dialog"], result.content)
        XCTAssertTrue(result.content.contains(#""Save Password?" (Not Now, Save)"#), result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, ["Sign in"])
    }
}

/// A sign-in screen whose button signs in and brings up "Save Password?" over the signed-in header.
private actor SignInDriver: PlatformDriver {
    private var signedIn = false
    private var prompt = false
    private(set) var taps: [String] = []

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "device", name: "Device", platform: .ios, osVersion: "27", state: .booted)
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "com.example.app", targetBundleID: "com.example.app")
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        let all: [ElementInfo] = if prompt {
            [
                Self.element("", "Save Password?", .sheet, Rect(x: 0, y: 500, width: 440, height: 456)),
                Self.element("", "Not Now", .button, Rect(x: 20, y: 880, width: 180, height: 50)),
                Self.element("", "Save", .button, Rect(x: 240, y: 880, width: 180, height: 50))
            ]
        } else if signedIn {
            [Self.element("account.header", "Account", .staticText, Rect(x: 20, y: 100, width: 400, height: 40))]
        } else {
            [Self.element("auth.sign_in", "Sign in", .button, Rect(x: 20, y: 300, width: 400, height: 50))]
        }
        return all.filter { element in selector.id.map { $0 == element.id } ?? true }
    }

    func waitForElement(_ selector: ElementSelector, timeout: AmooCore.Duration) async throws {
        guard try await !findElements(selector).isEmpty else {
            throw AmooError.timeout(operation: "waitForElement", duration: timeout)
        }
    }

    private static func element(_ id: String, _ label: String, _ type: ElementType, _ frame: Rect) -> ElementInfo {
        ElementInfo(id: id, label: label, type: type, frame: frame)
    }

    func tap(at point: Point) async throws {
        let hit = try await findElements(ElementSelector()).first { element in
            guard let frame = element.frame, element.type == .button else { return false }
            return (frame.x ... frame.x + frame.width).contains(point.x)
                && (frame.y ... frame.y + frame.height).contains(point.y)
        }
        guard let hit else { return }
        taps.append(hit.label)
        if hit.label == "Sign in" {
            signedIn = true
            prompt = true
        } else if hit.label == "Not Now" {
            prompt = false
        }
    }
}
