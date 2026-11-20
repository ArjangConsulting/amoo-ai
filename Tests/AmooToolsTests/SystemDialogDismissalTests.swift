import AmooCore
@testable import AmooTools
import XCTest

/// A system dialog in front of the app ("Save Password?", another app's "isn't responding") is named in
/// the failing step, and with `dismiss_system_dialogs=true` answered with its harmless button and retried.
final class SystemDialogDismissalTests: XCTestCase {
    func testAFailedStepNamesAnIOSSystemSheet() async {
        let driver = DialogDriver(platform: .ios, dialog: .savePassword)
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "assert_visible", arguments: ["id": "account.sign_out", "timeout_ms": "200"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains(#""Save Password?" (Not Now, Save)"#), result.content)
        XCTAssertNotNil(result.structuredContent?.objectValue?["blocking_dialog"])
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty, "naming a dialog never answers it")
    }

    func testOptInPressesNotNowAndRetries() async {
        let driver = DialogDriver(platform: .ios, dialog: .savePassword)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible",
            arguments: ["id": "account.sign_out", "timeout_ms": "200", "dismiss_system_dialogs": "true"]
        )
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, ["Not Now"])
        XCTAssertNotNil(result.structuredContent?.objectValue?["dismissed_dialog"])
    }

    func testAnotherAppsANRIsWaitedOutButTheTargetsOwnIsNot() async {
        let foreign = DialogDriver(platform: .android, dialog: .anr("Pixel Launcher isn't responding"))
        let answered = await DriverToolExecutor(driver: foreign).execute(
            toolName: "assert_visible",
            arguments: ["id": "account.sign_out", "timeout_ms": "200", "dismiss_system_dialogs": "true"]
        )
        XCTAssertFalse(answered.isError, answered.content)
        let foreignTaps = await foreign.taps
        XCTAssertEqual(foreignTaps, ["Wait"])

        let own = DialogDriver(platform: .android, dialog: .anr("Novalingo isn't responding"))
        let refused = await DriverToolExecutor(driver: own).execute(
            toolName: "assert_visible",
            arguments: ["id": "account.sign_out", "timeout_ms": "200", "dismiss_system_dialogs": "true"]
        )
        XCTAssertTrue(refused.isError)
        let ownTaps = await own.taps
        XCTAssertTrue(ownTaps.isEmpty, "the target app's own hang is a finding")
    }

    func testOwnershipIgnoresGenericPackageSegments() {
        let dialog = BlockingSystemDialog(title: "Android System isn't responding", actions: [])
        XCTAssertFalse(dialog.belongs(to: "com.novalingo.android.qa"))
        XCTAssertTrue(BlockingSystemDialog(title: "Novalingo isn't responding", actions: [])
            .belongs(to: "com.novalingo.android.qa"))
    }
}

/// A device showing one system dialog over a screen whose `account.sign_out` appears once it is answered.
actor DialogDriver: PlatformDriver {
    enum Dialog { case savePassword, anr(String) }

    private let platform: Platform
    private var dialog: Dialog?
    private(set) var taps: [String] = []

    init(platform: Platform, dialog: Dialog) {
        self.platform = platform
        self.dialog = dialog
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "device", name: "Device", platform: platform, osVersion: "27", state: .booted)
    }

    func currentApp() async throws -> CurrentApp {
        let front = platform == .android && dialog != nil ? "android" : "com.novalingo.android.qa"
        return CurrentApp(bundleID: front, targetBundleID: "com.novalingo.android.qa")
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        var all: [ElementInfo] = []
        switch dialog {
        case .savePassword:
            all = [
                Self.element("", "Save Password?", .sheet, Rect(x: 0, y: 500, width: 440, height: 456)),
                Self.element("", "Not Now", .button, Rect(x: 20, y: 880, width: 180, height: 50)),
                Self.element("", "Save", .button, Rect(x: 240, y: 880, width: 180, height: 50))
            ]
        case let .anr(title):
            all = [
                Self.element("alertTitle", title, .staticText, Rect(x: 40, y: 400, width: 360, height: 40)),
                Self.element("aerr_close", "Close app", .button, Rect(x: 40, y: 460, width: 360, height: 48)),
                Self.element("aerr_wait", "Wait", .button, Rect(x: 40, y: 520, width: 360, height: 48))
            ]
        case nil:
            all = [Self.element("account.sign_out", "Sign out", .button, Rect(x: 20, y: 300, width: 400, height: 50))]
        }
        return all.filter { element in selector.id.map { $0 == element.id } ?? true }
    }

    private static func element(_ id: String, _ label: String, _ type: ElementType, _ frame: Rect) -> ElementInfo {
        ElementInfo(id: id, label: label, type: type, frame: frame)
    }

    func tap(at point: Point) async throws {
        let labels = try await findElements(ElementSelector()).filter { element in
            guard let frame = element.frame, element.type == .button else { return false }
            return (frame.x ... frame.x + frame.width).contains(point.x)
                && (frame.y ... frame.y + frame.height).contains(point.y)
        }.map(\.label)
        taps += labels
        dialog = nil
    }
}
