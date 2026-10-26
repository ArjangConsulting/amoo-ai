// swiftlint:disable multiline_arguments
import AmooCore
import Foundation

extension DriverToolExecutor {
    func inspectionHighlight(
        report: inout AccessibilityInspection,
        baseline: ScreenObservation?,
        driver: any PlatformDriver,
        appID: String
    ) async -> ToolImageContent? {
        guard ["appleNativeAudit", "androidNativeATF"].contains(report.provider),
              !report.issues.isEmpty else { return nil }
        report.provenance["screenshot_status"] = "unavailable: capture could not be correlated with audit targets"
        guard let baseline, !report.requestedChecks.contains("dynamicType") else { return nil }
        let capture = await Self.withinBudget(milliseconds: 3000) {
            do {
                let screenshot = try await driver.takeScreenshot(format: .png)
                let after = try await driver.observeScreen(appID: appID)
                let foreground = try await driver.currentApp().bundleID
                let geometry = try await driver.screenGeometry()
                return (screenshot, after.token, foreground, geometry.widthPoints)
            } catch { return nil }
        }
        guard let (screenshot, token, foreground, width) = capture,
              width > 0, token == baseline.token, foreground == appID else { return nil }
        let issues = report.issues.compactMap { issue -> ElementA11yIssue? in
            guard let frame = issue.frame else { return nil }
            return ElementA11yIssue(
                id: issue.semantics?.reference ?? "", label: issue.label ?? "",
                type: issue.elementType, issue: issue.category, frame: frame
            )
        }
        guard !issues.isEmpty else { return nil }
        let bytes = Data(screenshot.bytes)
        guard let annotated = ScreenshotAnnotator.annotate(pngData: bytes, issues: issues, viewportWidth: width)
        else { return nil }
        let reference = sha256Hex(bytes)
        report.provenance["screenshot_sha256"] = reference
        report.provenance["annotated_screenshot_sha256"] = sha256Hex(annotated)
        report.provenance["screenshot_status"] = "post-audit capture; semantic snapshot unchanged across audit"
        for index in report.issues.indices where report.issues[index].frame != nil {
            report.issues[index].semantics?.attributes["screenshotSHA256"] = reference
        }
        return ToolImageContent(data: annotated, mimeType: ImageFormat.png.mimeType)
    }
}

// swiftlint:enable multiline_arguments
