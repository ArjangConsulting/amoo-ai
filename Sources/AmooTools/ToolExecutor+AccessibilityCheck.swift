import AmooCore
import AmooLogging
import Foundation
import StudioProtocol

/// One pass of `check_accessibility`: every opted-in check under one set of display settings.
struct AccessibilityCheckPass: Codable, Equatable {
    /// `default`, or the configuration this pass repeats the checks under (`dark_mode`, …).
    var configuration: String
    /// What the device reported for each setting this pass depends on, read back after changing it.
    var settings: [String: String]
    /// `evaluated`, `fail`, `notEvaluated`: whether this pass ran and what it found.
    var status: String
    var verdict: String
    var evaluatedChecks: [String]
    var notEvaluatedReasons: [String: String]
    var issues: [AccessibilityInspection.Issue]
    /// Issues the caller excluded for this call (`exclude_elements`), kept so the report shows them.
    var excludedIssues: [AccessibilityInspection.Issue] = []
    var error: String?
}

/// What a caller left out of one `check_accessibility` call: false positives or issues it accepts.
struct AccessibilityCheckExclusions: Codable, Equatable {
    /// Whole checks skipped for this call.
    var checks: [String]
    /// Per check, the element ids (or exact labels) whose issues are not counted.
    var elements: [String: [String]]
    var reason: String?

    static let none = Self(checks: [], elements: [:], reason: nil)

    var isEmpty: Bool {
        checks.isEmpty && elements.isEmpty
    }

    /// Parses `exclude_checks=contrast,target_size` and `exclude_elements=contrast:footer.text,names:Close`.
    /// Names must be checks the project opted in to, so a typo cannot hide a different check.
    static func parse(
        checks rawChecks: String?,
        elements rawElements: String?,
        reason: String?,
        optedIn: [AccessibilityCheckPolicy.Check]
    ) throws -> Self {
        let known = Set(optedIn.map(\.rawValue))
        func validated(_ name: String, argument: String) throws -> String {
            guard known.contains(name) else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "\(argument) names '\(name)', which is not an opted-in check"
                        + " (opted in: \(known.sorted().joined(separator: ", ")))."
                )
            }
            return name
        }
        let checks = try (rawChecks ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { try validated($0, argument: "exclude_checks") }
        var elements: [String: [String]] = [:]
        for entry in (rawElements ?? "").split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[1].isEmpty else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "exclude_elements entries are <check>:<element id or label>, got '\(entry)'."
                )
            }
            try elements[validated(parts[0], argument: "exclude_elements"), default: []].append(parts[1])
        }
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(checks: checks, elements: elements, reason: trimmedReason?.isEmpty == false ? trimmedReason : nil)
    }

    /// Whether `issue` belongs to an excluded element of one of the checks evaluated on `platform`.
    func excludes(_ issue: AccessibilityInspection.Issue, on platform: Platform) -> Bool {
        elements.contains { name, targets in
            guard let check = AccessibilityCheckPolicy.Check(rawValue: name),
                  check.nativeCategories(on: platform).contains(issue.category) else { return false }
            return targets.contains { $0 == issue.elementID || $0 == issue.label }
        }
    }
}

/// The `check_accessibility` result: every pass, the coverage of the opted-in list, and cleanup.
struct AccessibilityCheckReport: Codable, Equatable {
    var executionStatus: String
    /// `pass` only when every check this platform can run passed in every opted-in configuration.
    var verdict: String
    /// `restored`, `failed` or `notRequired`; a failure names the settings left changed.
    var cleanupStatus: String
    var platform: String
    var optedInChecks: [String]
    var optedInConfigurations: [String]
    /// Opted-in checks this platform's native provider has no audit for, with the reason.
    var unsupportedChecks: [String: String]
    /// What the caller left out of this call; excluded checks are skipped, never passed.
    var exclusions: AccessibilityCheckExclusions
    var passes: [AccessibilityCheckPass]
    /// Settings changed for the run and their original values, as restored.
    var originalSettings: [String: String]
    var cleanupErrors: [String: String]
    var limitations: [String]
}

extension AccessibilityCheckPolicy.Check {
    /// ATF checks that together cover a spoken name on Android.
    static let androidNameCategories = [
        "sufficientElementDescription", "editableContentDescription", "duplicateSpeakableText"
    ]

    /// The native audit categories that evaluate this check, or empty when the platform has none.
    func nativeCategories(on platform: Platform) -> [String] {
        switch (self, platform) {
        case (.names, .android): Self.androidNameCategories
        case (.names, _): ["sufficientElementDescription"]
        case (.targetSize, _): ["hitRegion"]
        case (.contrast, _): ["contrast"]
        case (.textClipping, .ios), (.textClipping, .macos): ["textClipped"]
        case (.textScaling, .ios), (.textScaling, .macos): ["dynamicType"]
        case (.traits, .ios), (.traits, .macos): ["trait"]
        case (.elementDetection, .ios), (.elementDetection, .macos): ["elementDetection"]
        default: []
        }
    }
}

extension AccessibilityCheckPolicy.Configuration {
    var setting: DisplaySetting {
        switch self {
        case .darkMode: .appearance
        case .largeText: .textSize
        case .increaseContrast: .increaseContrast
        }
    }
}

extension DriverToolExecutor {
    private static let checkLogger = AmooLogger.forType(AccessibilityCheckReport.self)

    // Runs every check `amoo.config.json` opts in to, once at default settings and once more under
    // each opted-in configuration, then puts every setting it changed back. One linear sequence.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func executeAccessibilityCheck(
        driver: any PlatformDriver,
        arguments: [String: String]
    ) async throws -> ToolResult {
        guard let appID = arguments["app_id"], !appID.isEmpty else {
            throw ToolExecutionError(code: "invalid_argument", message: "Requires app_id")
        }
        let policy: AccessibilityCheckPolicy
        switch accessibilityPolicy() {
        case .notConfigured:
            throw ToolExecutionError(
                code: "not_configured",
                message: "No accessibility checks are opted in. Run `amoo init`, or add an `accessibility`"
                    + " section to \(AmooProjectConfig.fileName) (see docs/accessibility-checks.md)."
            )
        case let .invalid(problem):
            throw ToolExecutionError(code: "invalid_config", message: problem)
        case let .configured(configured):
            policy = configured
        }
        guard !policy.enabledChecks.isEmpty else {
            throw ToolExecutionError(
                code: "not_configured",
                message: "\(AmooProjectConfig.fileName) opts in to no accessibility checks; configurations"
                    + " only repeat checks, so there is nothing to run."
            )
        }
        let settleMilliseconds = try settleArgument(arguments["settle_ms"])
        let exclusions = try AccessibilityCheckExclusions.parse(
            checks: arguments["exclude_checks"],
            elements: arguments["exclude_elements"],
            reason: arguments["exclude_reason"],
            optedIn: policy.enabledChecks
        )
        if let id = arguments["session_id"], let session = await sessionManager?.session(id), session.appID != appID {
            throw ToolExecutionError(code: "wrong_app", message: "Check target must match the session's app identity")
        }
        guard try await driver.currentApp().bundleID == appID else {
            throw ToolExecutionError(code: "wrong_app", message: "Check target is not the frontmost app")
        }
        let platform = try await driver.deviceInfo().platform
        var unsupported: [String: String] = [:]
        var categories: [String] = []
        for check in policy.enabledChecks where !exclusions.checks.contains(check.rawValue) {
            let mapped = check.nativeCategories(on: platform)
            if mapped.isEmpty {
                unsupported[check.rawValue] = "No \(platform.rawValue) native audit evaluates \(check.rawValue)."
            }
            categories += mapped.filter { !categories.contains($0) }
        }
        let configurations = policy.enabledConfigurations
        let touched = configurations.map(\.setting)
        Self.checkLogger.info(
            "Starting accessibility check",
            context: "checks=\(policy.enabledChecks.count) configurations=\(configurations.count) platform=\(platform)"
        )

        var originals: [DisplaySetting: String] = [:]
        var passes: [AccessibilityCheckPass] = []
        var unreadable: [String: String] = [:]
        for setting in touched {
            do {
                originals[setting] = try await driver.displaySetting(setting)
            } catch {
                unreadable[setting.rawValue] = "\(error)"
                Self.checkLogger.error("Cannot read display setting", error: error, context: "setting=\(setting)")
            }
        }

        let plan: [(name: String, values: [DisplaySetting: String])] = [(
            "default", Dictionary(uniqueKeysWithValues: touched.map { ($0, $0.defaultValue(for: platform)) })
        )] + configurations.map { configuration in
            var values = Dictionary(uniqueKeysWithValues: touched.map { ($0, $0.defaultValue(for: platform)) })
            values[configuration.setting] = configuration.setting.accessibilityValue(for: platform)
            return (configuration.rawValue, values)
        }

        // Set once the provider says it cannot audit at all, so later passes do not change settings for nothing.
        var providerUnsupported: String?
        for step in plan {
            if categories.isEmpty {
                passes.append(Self.skippedPass(step.name, reason: "No opted-in check is available on this platform."))
                continue
            }
            if let providerUnsupported {
                passes.append(Self.skippedPass(step.name, reason: providerUnsupported))
                continue
            }
            if let missing = step.values.keys.first(where: { originals[$0] == nil }) {
                passes.append(Self.skippedPass(
                    step.name,
                    reason: "Cannot read \(missing.rawValue), so it would not be restored: "
                        + (unreadable[missing.rawValue] ?? "unavailable")
                ))
                continue
            }
            var observed: [String: String] = [:]
            var applyError: String?
            for (setting, value) in step.values.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                do {
                    let current = try await driver.displaySetting(setting)
                    let reported = current == value ? current
                        : try await driver.setDisplaySetting(setting, to: value)
                    observed[setting.rawValue] = reported
                    if reported != value {
                        applyError = "Requested \(setting.rawValue)=\(value) but the device reports \(reported)."
                    }
                } catch {
                    applyError = "Cannot set \(setting.rawValue)=\(value): \(error)"
                    Self.checkLogger.error("Cannot apply display setting", error: error, context: "setting=\(setting)")
                }
            }
            if let applyError {
                var pass = Self.skippedPass(step.name, reason: applyError)
                pass.settings = observed
                passes.append(pass)
                continue
            }
            if !step.values.isEmpty, settleMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(settleMilliseconds))
            }
            guard await (try? driver.currentApp().bundleID) == appID else {
                var pass = Self.skippedPass(step.name, reason: "The app left the foreground after the setting changed.")
                pass.settings = observed
                passes.append(pass)
                continue
            }
            Self.checkLogger.debug("Running native audit", context: "pass=\(step.name) categories=\(categories.count)")
            do {
                var report = try await driver.inspectAccessibility(
                    appID: appID, operation: "nativeAudit", categories: categories, steps: 1, direction: "forward"
                )
                let excluded = report.issues.filter { exclusions.excludes($0, on: platform) }
                if !excluded.isEmpty {
                    report.issues.removeAll { exclusions.excludes($0, on: platform) }
                    // The provider's verdict counted the excluded issues; re-derive it from what remains.
                    if report.issues.isEmpty, report.status == "fail" {
                        report.status = "pass"
                    }
                }
                if report.executionStatus == "unsupported" {
                    providerUnsupported = report.error ?? report.limitations.first ?? "Native audit is unsupported."
                }
                passes.append(AccessibilityCheckPass(
                    configuration: step.name,
                    settings: observed,
                    status: report.executionStatus == "succeeded" ? "evaluated" : "notEvaluated",
                    verdict: report.verdict,
                    evaluatedChecks: report.evaluatedChecks,
                    notEvaluatedReasons: report.notEvaluatedReasons,
                    issues: report.issues,
                    excludedIssues: excluded,
                    error: report.error
                ))
            } catch {
                Self.checkLogger.error("Native audit failed", error: error, context: "pass=\(step.name)")
                var pass = Self.skippedPass(step.name, reason: "Native audit failed: \(error)")
                pass.settings = observed
                passes.append(pass)
            }
        }

        var cleanupErrors: [String: String] = [:]
        for (setting, original) in originals.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            do {
                let current = try await driver.displaySetting(setting)
                guard current != original else { continue }
                let restored = try await driver.setDisplaySetting(setting, to: original)
                if restored != original {
                    cleanupErrors[setting.rawValue] = "Restored \(original) but the device reports \(restored)."
                }
            } catch {
                cleanupErrors[setting.rawValue] = "\(error)"
                Self.checkLogger.error("Cannot restore display setting", error: error, context: "setting=\(setting)")
            }
        }

        let report = Self.checkReport(
            policy: policy,
            platform: platform,
            categories: categories,
            unsupported: unsupported,
            exclusions: exclusions,
            passes: passes,
            originals: originals,
            cleanupErrors: cleanupErrors
        )
        Self.checkLogger.info(
            "Finished accessibility check",
            context: "verdict=\(report.verdict) cleanup=\(report.cleanupStatus) passes=\(passes.count)"
        )
        return try ToolResult(
            content: Self.checkSummary(report),
            isError: report.verdict != "pass" || report.cleanupStatus == "failed",
            structuredContent: Value(report)
        )
    }

    private func settleArgument(_ raw: String?) throws -> Int {
        guard let raw else { return 1500 }
        guard let value = Int(raw), (0 ... 10000).contains(value) else {
            throw ToolExecutionError(code: "invalid_argument", message: "settle_ms must be an integer in 0...10000")
        }
        return value
    }

    private static func skippedPass(_ configuration: String, reason: String) -> AccessibilityCheckPass {
        AccessibilityCheckPass(
            configuration: configuration,
            settings: [:],
            status: "notEvaluated",
            verdict: "notAssessed",
            evaluatedChecks: [],
            notEvaluatedReasons: [:],
            issues: [],
            error: reason
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func checkReport(
        policy: AccessibilityCheckPolicy,
        platform: Platform,
        categories: [String],
        unsupported: [String: String],
        exclusions: AccessibilityCheckExclusions,
        passes: [AccessibilityCheckPass],
        originals: [DisplaySetting: String],
        cleanupErrors: [String: String]
    ) -> AccessibilityCheckReport {
        let failed = passes.contains { $0.verdict == "fail" }
        let complete = !categories.isEmpty && passes.allSatisfy {
            $0.status == "evaluated" && $0.verdict == "pass" && Set($0.evaluatedChecks) == Set(categories)
        }
        let executed = passes.contains { $0.status == "evaluated" }
        return AccessibilityCheckReport(
            executionStatus: executed ? "succeeded" : "failed",
            verdict: failed ? "fail" : complete ? "pass" : "notAssessed",
            cleanupStatus: originals.isEmpty ? "notRequired" : cleanupErrors.isEmpty ? "restored" : "failed",
            platform: platform.rawValue,
            optedInChecks: policy.enabledChecks.map(\.rawValue),
            optedInConfigurations: policy.enabledConfigurations.map(\.rawValue),
            unsupportedChecks: unsupported,
            exclusions: exclusions,
            passes: passes,
            originalSettings: Dictionary(uniqueKeysWithValues: originals.map { ($0.key.rawValue, $0.value) }),
            cleanupErrors: cleanupErrors,
            limitations: [
                "Native audit of the current screen in each configuration; not whole-app conformance or a"
                    + " screen-reader task result.",
                "Settings are restored when the call ends; a killed process can leave them changed."
            ]
        )
    }

    static func checkSummary(_ report: AccessibilityCheckReport) -> String {
        let configurations = report.optedInConfigurations.isEmpty
            ? "none" : report.optedInConfigurations.joined(separator: ",")
        var lines = [
            "check_accessibility: verdict=\(report.verdict), cleanup=\(report.cleanupStatus),"
                + " checks=\(report.optedInChecks.joined(separator: ",")), configurations=\(configurations)."
        ]
        for pass in report.passes {
            let settings = pass.settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            let scope = settings.isEmpty ? "" : " (\(settings.joined(separator: ", ")))"
            if pass.status != "evaluated" {
                lines.append("- \(pass.configuration)\(scope): not evaluated: \(pass.error ?? "unknown reason")")
                continue
            }
            let gaps = pass.notEvaluatedReasons.keys.sorted()
            lines.append(
                "- \(pass.configuration)\(scope): \(pass.verdict), \(pass.issues.count) issue(s)"
                    + (pass.excludedIssues.isEmpty ? "" : ", \(pass.excludedIssues.count) excluded")
                    + (gaps.isEmpty ? "" : ", not evaluated: \(gaps.joined(separator: ","))")
                    + issueSummary(pass.issues).replacingOccurrences(of: "\n- ", with: "\n    - ")
            )
        }
        if !report.exclusions.isEmpty {
            let excludedChecks = report.exclusions.checks
            let checks = excludedChecks.isEmpty ? [] : ["checks " + excludedChecks.joined(separator: ",")]
            let elements = report.exclusions.elements.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.joined(separator: "; "))" }
            lines.append(
                "- excluded by caller: " + (checks + elements).joined(separator: "; ")
                    + (report.exclusions.reason.map { " (reason: \($0))" } ?? "")
            )
        }
        for (check, reason) in report.unsupportedChecks.sorted(by: { $0.key < $1.key }) {
            lines.append("- \(check): unsupported: \(reason)")
        }
        for (setting, error) in report.cleanupErrors.sorted(by: { $0.key < $1.key }) {
            lines.append("- cleanup: \(setting) not restored to \(report.originalSettings[setting] ?? "?"): \(error)")
        }
        return lines.joined(separator: "\n")
    }
}
