import AmooCore
@testable import AmooTools
import Foundation
import SessionCompiler
import StudioProtocol
import TestSession
import XCTest

// swiftlint:disable multiline_arguments

/// `check_accessibility` runs exactly the checks the project opted in to, once per opted-in
/// configuration, and puts back every display setting it changed.
final class AccessibilityCheckToolTests: XCTestCase {
    private func executor(
        _ driver: SettingsDriver,
        policy: AccessibilityCheckResolution
    ) -> DriverToolExecutor {
        DriverToolExecutor(driver: driver, accessibilityPolicy: { policy })
    }

    private func configured(
        _ checks: [AccessibilityCheckPolicy.Check],
        _ configurations: [AccessibilityCheckPolicy.Configuration] = []
    ) -> AccessibilityCheckResolution {
        .configured(AccessibilityCheckPolicy(checks: checks, configurations: configurations))
    }

    private func report(_ result: ToolResult) throws -> AccessibilityCheckReport {
        let data = try JSONEncoder().encode(XCTUnwrap(result.structuredContent))
        return try JSONDecoder().decode(AccessibilityCheckReport.self, from: data)
    }

    func testRefusesUntilTheProjectOptsIn() async {
        let driver = SettingsDriver()
        let result = await executor(driver, policy: .notConfigured)
            .execute(toolName: "check_accessibility", arguments: ["app_id": "com.example.app"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("No accessibility checks are opted in"), result.content)
        let audits = await driver.auditedCategories
        XCTAssertTrue(audits.isEmpty)
    }

    func testRunsEachConfigurationAndRestoresTheOriginalSettings() async throws {
        let driver = SettingsDriver(settings: [.appearance: "dark", .textSize: "extra-large"])
        let result = await executor(driver, policy: configured([.names, .contrast], [.darkMode, .largeText]))
            .execute(toolName: "check_accessibility", arguments: ["app_id": "com.example.app", "settle_ms": "0"])
        XCTAssertFalse(result.isError, result.content)
        let report = try report(result)
        XCTAssertEqual(report.verdict, "pass")
        XCTAssertEqual(report.cleanupStatus, "restored")
        XCTAssertEqual(report.passes.map(\.configuration), ["default", "dark_mode", "large_text"])
        XCTAssertEqual(report.passes[0].settings, ["appearance": "light", "text_size": "large"])
        XCTAssertEqual(report.passes[1].settings["appearance"], "dark")
        XCTAssertEqual(report.passes[2].settings["text_size"], "accessibility-extra-extra-extra-large")
        let audits = await driver.auditedCategories
        XCTAssertEqual(audits, Array(repeating: ["sufficientElementDescription", "contrast"], count: 3))
        let settings = await driver.settings
        XCTAssertEqual(settings, [.appearance: "dark", .textSize: "extra-large"])
    }

    func testAnIssueInOneConfigurationFailsTheCallButEveryPassRuns() async throws {
        let driver = SettingsDriver()
        await driver.failContrast(whenAppearanceIs: "dark")
        let result = await executor(driver, policy: configured([.contrast], [.darkMode]))
            .execute(toolName: "check_accessibility", arguments: ["app_id": "com.example.app", "settle_ms": "0"])
        XCTAssertTrue(result.isError)
        let report = try report(result)
        XCTAssertEqual(report.verdict, "fail")
        XCTAssertEqual(report.passes.map(\.verdict), ["pass", "fail"])
        XCTAssertEqual(report.cleanupStatus, "restored")
        XCTAssertTrue(result.content.contains("dark_mode (appearance=dark): fail, 1 issue(s)"), result.content)
    }

    func testAnExcludedElementIsReportedButDoesNotFail() async throws {
        let driver = SettingsDriver()
        await driver.failContrast(whenAppearanceIs: "dark")
        let result = await executor(driver, policy: configured([.contrast], [.darkMode])).execute(
            toolName: "check_accessibility",
            arguments: [
                "app_id": "com.example.app", "settle_ms": "0",
                "exclude_elements": "contrast:footer.legal", "exclude_reason": "Decorative footer text"
            ]
        )
        XCTAssertFalse(result.isError, result.content)
        let report = try report(result)
        XCTAssertEqual(report.verdict, "pass")
        XCTAssertEqual(report.passes[1].excludedIssues.count, 1)
        XCTAssertEqual(report.exclusions.reason, "Decorative footer text")
        XCTAssertTrue(result.content.contains("excluded by caller: contrast: footer.legal"), result.content)
    }

    func testAnExcludedCheckIsNotAuditedAndAnUnknownOneIsRejected() async throws {
        let driver = SettingsDriver()
        let policy = configured([.names, .contrast])
        let result = await executor(driver, policy: policy).execute(
            toolName: "check_accessibility",
            arguments: ["app_id": "com.example.app", "exclude_checks": "contrast"]
        )
        XCTAssertFalse(result.isError, result.content)
        let audits = await driver.auditedCategories
        XCTAssertEqual(audits, [["sufficientElementDescription"]])
        XCTAssertEqual(try report(result).exclusions.checks, ["contrast"])

        let typo = await executor(driver, policy: policy).execute(
            toolName: "check_accessibility",
            arguments: ["app_id": "com.example.app", "exclude_checks": "traits"]
        )
        XCTAssertTrue(typo.isError)
        XCTAssertTrue(typo.content.contains("not an opted-in check"), typo.content)
    }

    func testAnExcludedConfigurationIsSkippedWithoutChangingItsSetting() async throws {
        let driver = SettingsDriver()
        let policy = configured([.contrast], [.darkMode, .largeText])
        let result = await executor(driver, policy: policy).execute(
            toolName: "check_accessibility",
            arguments: ["app_id": "com.example.app", "settle_ms": "0", "exclude_configurations": "large_text"]
        )
        XCTAssertFalse(result.isError, result.content)
        let report = try report(result)
        XCTAssertEqual(report.passes.map(\.configuration), ["default", "dark_mode"])
        XCTAssertEqual(report.exclusions.configurations, ["large_text"])
        let writes = await driver.writes
        XCTAssertFalse(writes.contains { $0.hasPrefix("text_size") }, "\(writes)")
        XCTAssertTrue(result.content.contains("configurations large_text"), result.content)

        let typo = await executor(driver, policy: policy).execute(
            toolName: "check_accessibility",
            arguments: ["app_id": "com.example.app", "exclude_configurations": "increase_contrast"]
        )
        XCTAssertTrue(typo.isError)
    }

    func testChecksAndroidCannotRunAreListedAsUnsupported() async throws {
        let driver = SettingsDriver(platform: .android)
        let result = await executor(driver, policy: configured([.names, .traits]))
            .execute(toolName: "check_accessibility", arguments: ["app_id": "com.example.app"])
        let report = try report(result)
        XCTAssertNotNil(report.unsupportedChecks["traits"])
        let audits = await driver.auditedCategories
        XCTAssertEqual(audits, [AccessibilityCheckPolicy.Check.androidNameCategories])
    }

    func testAConfigurationWhoseSettingCannotBeReadIsNotAssessed() async throws {
        let driver = SettingsDriver(settings: [:])
        let result = await executor(driver, policy: configured([.contrast], [.increaseContrast]))
            .execute(toolName: "check_accessibility", arguments: ["app_id": "com.example.app", "settle_ms": "0"])
        XCTAssertTrue(result.isError)
        let report = try report(result)
        XCTAssertEqual(report.verdict, "notAssessed")
        XCTAssertEqual(report.passes.map(\.status), ["notEvaluated", "notEvaluated"])
        let audits = await driver.auditedCategories
        XCTAssertTrue(audits.isEmpty, "Never change a setting that cannot be restored")
    }

    func testAnUnsupportedProviderStopsBeforeChangingMoreSettings() async throws {
        let driver = SettingsDriver()
        await driver.reportUnsupported()
        let result = await executor(driver, policy: configured([.contrast], [.darkMode, .largeText]))
            .execute(toolName: "check_accessibility", arguments: ["app_id": "com.example.app", "settle_ms": "0"])
        XCTAssertTrue(result.isError)
        let audits = await driver.auditedCategories
        XCTAssertEqual(audits.count, 1, "Only the default pass reaches the provider")
        let writes = await driver.writes
        XCTAssertTrue(writes.isEmpty, "Settings already at their defaults are not rewritten: \(writes)")
        XCTAssertEqual(try report(result).passes.map(\.status), ["notEvaluated", "notEvaluated", "notEvaluated"])
    }

    func testIsRecordedAsAnAssertionThatGeneratedTestsReportAsExcluded() async throws {
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let session = try await manager.startSession(appID: "com.example.frontmost", platform: .ios)
        let driver = try XCTUnwrap(session.driver as? MockDriver)
        await driver.stubAccessibilityInspection(AccessibilityInspection(
            status: "pass", provider: "appleNativeAudit",
            requestedChecks: ["hitRegion"], evaluatedChecks: ["hitRegion"]
        ))
        let executor = DriverToolExecutor(
            driver: MockDriver(),
            sessionManager: manager,
            accessibilityPolicy: { .configured(AccessibilityCheckPolicy(checks: [.targetSize], configurations: [])) }
        )
        let result = await executor.execute(
            toolName: "check_accessibility",
            arguments: ["app_id": session.appID, "session_id": session.id]
        )
        XCTAssertFalse(result.isError, result.content)
        let report = await SessionReport.make(from: session)
        try await manager.endSession(session.id)
        XCTAssertEqual(report.actions.first?.intent, .assertion)
        let plan = try SessionPlanCompiler.compile(report: report, testName: "Check", testDescription: nil)
        XCTAssertEqual(plan.studioTest.compiledPlan?.excludedWarnings.count, 1)
    }
}

/// A device whose display settings behave like the real store: a write is what a read returns.
actor SettingsDriver: PlatformDriver {
    private(set) var settings: [DisplaySetting: String]
    private(set) var auditedCategories: [[String]] = []
    private let platform: Platform
    private var contrastFailureAppearance: String?
    private var unsupported = false
    private(set) var writes: [String] = []

    func reportUnsupported() {
        unsupported = true
    }

    init(
        platform: Platform = .ios,
        settings: [DisplaySetting: String] = [.appearance: "light", .textSize: "large", .increaseContrast: "disabled"]
    ) {
        self.platform = platform
        self.settings = settings
    }

    func failContrast(whenAppearanceIs appearance: String) {
        contrastFailureAppearance = appearance
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "com.example.app", targetBundleID: "com.example.app")
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "settings", name: "Settings", platform: platform, osVersion: "27.0", state: .booted)
    }

    func displaySetting(_ setting: DisplaySetting) async throws -> String {
        guard let value = settings[setting] else {
            throw AmooError.unsupportedCapability(key: "config.\(setting.rawValue)", reason: "unreadable")
        }
        return value
    }

    func setDisplaySetting(_ setting: DisplaySetting, to value: String) async throws -> String {
        writes.append("\(setting.rawValue)=\(value)")
        settings[setting] = value
        return value
    }

    func inspectAccessibility(
        appID _: String, operation _: String, categories: [String], steps _: Int, direction _: String
    ) async throws -> AccessibilityInspection {
        auditedCategories.append(categories)
        if unsupported {
            return AccessibilityInspection(status: "unsupported", provider: "platform", error: "No native audit")
        }
        let failing = contrastFailureAppearance != nil && settings[.appearance] == contrastFailureAppearance
            && categories.contains("contrast")
        return AccessibilityInspection(
            status: failing ? "fail" : "pass",
            provider: platform == .android ? "androidNativeATF" : "appleNativeAudit",
            issues: failing ? [.init(
                category: "contrast", description: "Contrast failed", details: "", elementID: "footer.legal",
                label: "Terms", semantics: ElementSemantics(attributes: ["resultType": "ERROR"])
            )] : [],
            requestedChecks: categories,
            evaluatedChecks: categories
        )
    }
}

// swiftlint:enable multiline_arguments
