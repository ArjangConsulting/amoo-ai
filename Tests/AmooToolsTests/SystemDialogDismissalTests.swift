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

    /// Once the link that shows the sheet inside the app's tree drops, the app's tree is the application
    /// element and an unnamed container; only a read of Safari's view service, which draws it, finds it.
    func testASheetOnlyItsHostProcessShowsIsNamedAndAnswered() async {
        let named = await DriverToolExecutor(driver: DialogDriver(platform: .ios, dialog: .savePassword, hosted: true))
            .execute(toolName: "assert_visible", arguments: ["id": "account.sign_out", "timeout_ms": "200"])
        XCTAssertTrue(named.content.contains(#""Save Password?" (Not Now, Save)"#), named.content)

        let driver = DialogDriver(platform: .ios, dialog: .savePassword, hosted: true)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible",
            arguments: ["id": "account.sign_out", "timeout_ms": "200", "dismiss_system_dialogs": "true"]
        )
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, ["Not Now"])
        let hostReads = await driver.hostReads
        XCTAssertGreaterThan(hostReads, 0)
        XCTAssertEqual(BlockingSystemDialog.iosSheetHosts, [DialogDriver.sheetHost])
    }

    func testAScreenWithoutASheetAnywhereIsAPlainMiss() async {
        let driver = DialogDriver(platform: .ios, dialog: nil)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible",
            arguments: ["id": "account.missing", "timeout_ms": "200", "dismiss_system_dialogs": "true"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertNil(result.structuredContent?.objectValue?["blocking_dialog"])
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testTheAppsOwnAlertIsNamedButNeverAnswered() async {
        let driver = DialogDriver(platform: .ios, dialog: .appAlert)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible",
            arguments: ["id": "account.sign_out", "timeout_ms": "200", "dismiss_system_dialogs": "true"]
        )
        XCTAssertTrue(result.isError, "cancelling the app's alert would hide a behaviour change")
        XCTAssertTrue(result.content.contains(#"A dialog is in front: "Discard changes?""#), result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["blocking_dialog"]?.objectValue?["system"], .bool(false))
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    func testOnlyKnownAppleTitlesAreSystemPrompts() {
        XCTAssertTrue(BlockingSystemDialog.isAppleSystemPrompt("Save Password?"))
        XCTAssertTrue(BlockingSystemDialog.isAppleSystemPrompt("Update Password?"))
        XCTAssertFalse(BlockingSystemDialog.isAppleSystemPrompt("Discard changes?"))
        XCTAssertFalse(BlockingSystemDialog.isAppleSystemPrompt("Delete password?"))
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

        let own = DialogDriver(platform: .android, dialog: .anr("Exampleapp isn't responding"))
        let refused = await DriverToolExecutor(driver: own).execute(
            toolName: "assert_visible",
            arguments: ["id": "account.sign_out", "timeout_ms": "200", "dismiss_system_dialogs": "true"]
        )
        XCTAssertTrue(refused.isError)
        let ownTaps = await own.taps
        XCTAssertTrue(ownTaps.isEmpty, "the target app's own hang is a finding")
    }

    func testAPressDroppedWhileTheSheetAppearsIsMadeAgain() async {
        let driver = DialogDriver(platform: .ios, dialog: .savePassword, droppedPresses: 1)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible",
            arguments: ["id": "account.sign_out", "timeout_ms": "200", "dismiss_system_dialogs": "true"]
        )
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, ["Not Now", "Not Now"])
    }

    func testTheHintNeverSuggestsTheSwitchTheCallAlreadyHas() async {
        let driver = DialogDriver(platform: .ios, dialog: .savePassword, droppedPresses: 10)
        let executor = DriverToolExecutor(driver: driver)
        await executor.setDismissSystemDialogsByDefault(true)
        let result = await executor.execute(
            toolName: "assert_visible", arguments: ["id": "account.sign_out", "timeout_ms": "200"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(
            result.content
                .contains("dismiss_system_dialogs is on, but it was still in front after amoo pressed Not Now"),
            result.content
        )
        XCTAssertFalse(result.content.contains("pass dismiss_system_dialogs=true"), result.content)
    }

    func testOwnershipIgnoresGenericPackageSegments() {
        let dialog = BlockingSystemDialog(title: "Android System isn't responding", actions: [])
        XCTAssertFalse(dialog.belongs(to: "com.exampleapp.android.qa"))
        XCTAssertTrue(BlockingSystemDialog(title: "Exampleapp isn't responding", actions: [])
            .belongs(to: "com.exampleapp.android.qa"))
    }
}

/// A device showing one system dialog over a screen whose `account.sign_out` appears once it is answered.
actor DialogDriver: PlatformDriver {
    enum Dialog { case savePassword, appAlert, anr(String) }

    static let sheetHost = "com.apple.SafariViewService"

    private let platform: Platform
    private var dialog: Dialog?
    private(set) var taps: [String] = []
    /// Presses the dialog ignores, as a sheet still sliding in does.
    private var droppedPresses: Int
    /// The sheet shows only in a read of `sheetHost`; the app's tree is the application element alone.
    private let hosted: Bool
    private(set) var hostReads = 0

    init(platform: Platform, dialog: Dialog?, droppedPresses: Int = 0, hosted: Bool = false) {
        self.platform = platform
        self.dialog = dialog
        self.droppedPresses = droppedPresses
        self.hosted = hosted
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil)
    }

    func findElements(_ selector: ElementSelector, appID: String?) async throws -> [ElementInfo] {
        guard hosted, dialog != nil else { return screen(selector) }
        guard appID == Self.sheetHost else {
            return [
                Self.element("", "ExampleApp", .other, Rect(x: 0, y: 0, width: 440, height: 956)),
                Self.element("", "", .other, Rect(x: 0, y: 0, width: 440, height: 956))
            ].filter { element in selector.id.map { $0 == element.id } ?? true }
        }
        hostReads += 1
        return screen(selector)
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "device", name: "Device", platform: platform, osVersion: "27", state: .booted)
    }

    func currentApp() async throws -> CurrentApp {
        let front = platform == .android && dialog != nil ? "android" : "com.exampleapp.android.qa"
        return CurrentApp(bundleID: front, targetBundleID: "com.exampleapp.android.qa")
    }

    /// Everything on screen, the dialog included.
    private func screen(_ selector: ElementSelector) -> [ElementInfo] {
        var all: [ElementInfo] = []
        switch dialog {
        case .savePassword:
            all = [
                Self.element("", "Save Password?", .sheet, Rect(x: 0, y: 500, width: 440, height: 456)),
                Self.element("", "Not Now", .button, Rect(x: 20, y: 880, width: 180, height: 50)),
                Self.element("", "Save", .button, Rect(x: 240, y: 880, width: 180, height: 50))
            ]
        case .appAlert:
            all = [
                Self.element("", "Discard changes?", .alert, Rect(x: 60, y: 380, width: 320, height: 200)),
                Self.element("", "Cancel", .button, Rect(x: 60, y: 520, width: 160, height: 50)),
                Self.element("", "Discard", .button, Rect(x: 220, y: 520, width: 160, height: 50))
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
        let labels = screen(ElementSelector()).filter { element in
            guard let frame = element.frame, element.type == .button else { return false }
            return (frame.x ... frame.x + frame.width).contains(point.x)
                && (frame.y ... frame.y + frame.height).contains(point.y)
        }.map(\.label)
        taps += labels
        guard droppedPresses == 0 else {
            droppedPresses -= 1
            return
        }
        dialog = nil
    }
}
