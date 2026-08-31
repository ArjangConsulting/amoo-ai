import AmooCore
import AuditEngine
import Foundation
import MCP
import TestSession

extension DriverToolExecutor {
    func executeNavigateTo(
        description: String,
        timeoutMS: Int,
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let lowered = description.lowercased()

        // (a) If the current screen already matches, succeed immediately.
        let initial = try await driver.getScreenContext()
        if screenContextMatches(initial, query: lowered) {
            return .success(
                "Already on target screen.\n\(initial.summary)",
                structuredContent: .object([
                    "navigated": .bool(false),
                    "matched_current_screen": .bool(true),
                    "screen_summary": .string(initial.summary)
                ])
            )
        }

        // (b) Search elements; tap the first interactable match.
        let candidate = try await findFirstNavigableElement(query: description, driver: driver)
        guard let target = candidate else {
            return ToolResult(
                content: """
                navigate_to failed: no element matches '\(description)'.
                Current screen: \(initial.summary)
                """,
                isError: true,
                structuredContent: .object([
                    "navigated": .bool(false),
                    "reason": .string("no_match"),
                    "screen_summary": .string(initial.summary)
                ])
            )
        }

        let selector = ElementSelector(
            id: target.id.isEmpty ? nil : target.id,
            label: target.label.isEmpty ? nil : target.label
        )
        try await driver.tapElement(selector)
        try? await Task.sleep(for: .milliseconds(800))

        // Wait for screen change up to the requested timeout.
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        var current = initial
        while Date() < deadline {
            current = await (try? driver.getScreenContext()) ?? current
            if current.summary != initial.summary {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        return .success(
            "Tapped '\(preferredElementName(label: target.label, id: target.id) ?? target.id)'.\n\(current.summary)",
            structuredContent: .object([
                "navigated": .bool(true),
                "element_id": .string(target.id),
                "element_label": .string(target.label),
                "screen_summary": .string(current.summary)
            ])
        )
    }

    /// Confirms a launch actually took, polling because the frontmost app during the launch
    /// animation is still the previous app (or the home screen). Reading `currentApp()` once,
    /// immediately after `launchApp`, reports that stale value and makes a healthy launch look
    /// like a failure.
    func verifyLaunch(
        appID: String,
        driver: any PlatformDriver,
        timeoutMS: Int = 5000
    ) async -> ToolResult {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        let unverified = ToolResult.success(
            "App launched: \(appID) (verified=false)",
            structuredContent: .object(["app_id": .string(appID), "verified": .bool(false)])
        )
        var lastFrontmost: String?
        repeat {
            let current = try? await driver.currentApp()
            let frontmost = current?.bundleID
            if let frontmost, !frontmost.isEmpty {
                lastFrontmost = frontmost
            }
            if frontmost == appID {
                return .success(
                    "App launched: \(appID) (verified=true)",
                    structuredContent: .object(["app_id": .string(appID), "verified": .bool(true)])
                )
            }
            // `appState`'s `.running` was tried here as a second, faster success signal, and
            // reverted: confirmed live against a real device that `.state == .runningForeground`
            // can read true while XCUITest's own app-resolution machinery is still genuinely
            // stuck — a launch this trusted as "verified=true" was followed by "Find the Target
            // Application" retrying continuously for 140+ seconds, and every later test that
            // touched the fixture UI in that run failed. `.state` is a fine building block for
            // other checks; treating it as sufficient proof a launch is *interactively ready*
            // is not. Only `frontmost` is trusted for that here.
            //
            // A driver that never reports a frontmost app can never confirm the launch this way,
            // so polling it further only burns the timeout. Report the launch as unverified
            // straight away instead.
            if lastFrontmost == nil, await (try? driver.appState(appID: appID)) == nil {
                return unverified
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline

        guard let lastFrontmost else {
            return unverified
        }
        return ToolResult(
            content: "device_launch_app failed: frontmost app is \(lastFrontmost), expected \(appID)",
            isError: true,
            structuredContent: .object(["app_id": .string(appID), "verified": .bool(false)])
        )
    }

    func executeSetText(
        selector: ElementSelector,
        value: String,
        driver: any PlatformDriver,
        appID: String? = nil
    ) async throws -> ToolResult {
        guard let matched = try await resolveElement(selector: selector, driver: driver, appID: appID) else {
            return .error("set_text failed: no text field matched the selector")
        }
        guard matched.isVisible, matched.isEnabled else {
            return .error("set_text failed: matched field is not visible and enabled")
        }
        let stableSelector = matched.id.isEmpty
            ? ElementSelector(label: matched.label)
            : ElementSelector(id: matched.id)
        let before = matched.value ?? ""
        try await driver.setText(stableSelector, text: value)

        let updated = try await driver.findElements(stableSelector, appID: appID).first
        let observed = updated?.value ?? ""
        // A secure field reports a mask rather than what was typed, so an exact match is not
        // always available. Falling back to "non-empty" alone would pass on a field that never
        // changed — the value has to have actually moved off what was there before.
        let verified = observed == value || (!value.isEmpty && !observed.isEmpty && observed != before)
        guard verified else {
            return ToolResult(
                content: "set_text failed: field [\(matched.id)] did not expose an updated value.",
                isError: true,
                structuredContent: .object([
                    "verified": .bool(false),
                    "element_id": .string(matched.id),
                    "element_label": .string(matched.label),
                    "value_length": .int(value.count)
                ])
            )
        }
        return .success(
            "Filled verified field [\(matched.id)] \(matched.label) with \(value.count) char(s).",
            structuredContent: .object([
                "verified": .bool(true),
                "element_id": .string(matched.id),
                "element_label": .string(matched.label),
                "value_length": .int(value.count)
            ])
        )
    }

    enum ElementAssertionKind {
        /// On screen. Deliberately weaker than `.enabled`: a disabled-but-present control is
        /// visible, and asserting otherwise would make `assert_visible` silently mean
        /// "visible and interactive".
        ///
        /// `assert_visible` takes a precise selector *or* a natural-language `description`, and
        /// routes here only for the former. It used to accept `description` alone, which made it
        /// the odd one out beside `assert_enabled` / `assert_absent` — both take either — and
        /// forced a caller holding an exact accessibility id to degrade it into a text guess.
        /// `SessionPlanCompiler.translateAssertVisible` has always expected a recorded
        /// `assert_visible` to be able to carry id/label/contains_text; until now the tool could
        /// never produce one.
        case visible
        case enabled
        case absent
        case value
    }

    func executeElementAssertion(
        kind: ElementAssertionKind,
        selector: ElementSelector,
        arguments: [String: String],
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let timeoutMS = arguments["timeout_ms"].flatMap(Int.init) ?? 5000
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        repeat {
            let match = try await resolveElement(selector: selector, driver: driver, appID: appID)
            switch kind {
            case .absent where match == nil:
                return assertionSuccess("Element is absent", element: nil)
            case .visible:
                if let match, match.isVisible {
                    return assertionSuccess("Element is visible", element: match)
                }
            case .enabled:
                if let match, match.isVisible, match.isEnabled {
                    return assertionSuccess("Element is visible and enabled", element: match)
                }
            case .value:
                if let match, valueMatches(match.value, arguments: arguments) {
                    return assertionSuccess("Element value matches", element: match)
                }
            case .absent:
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline

        return ToolResult(
            content: "Assertion failed after \(timeoutMS)ms.",
            isError: true,
            structuredContent: .object(["passed": .bool(false)])
        )
    }

    func assertionSuccess(_ message: String, element: ElementInfo?) -> ToolResult {
        .success(
            message,
            structuredContent: .object([
                "passed": .bool(true),
                "element_id": .string(element?.id ?? ""),
                "element_label": .string(element?.label ?? "")
            ])
        )
    }

    func valueMatches(_ actual: String?, arguments: [String: String]) -> Bool {
        guard let actual else { return false }
        if let expected = arguments["expected"] {
            return actual == expected
        }
        if let contains = arguments["contains"] {
            return actual.contains(contains)
        }
        return false
    }

    func executeAssertScreenChanged(
        baseline: String,
        timeoutMS: Int,
        driver: any PlatformDriver
    ) async -> ToolResult {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000)
        repeat {
            if let context = try? await driver.getScreenContext() {
                let current = screenToken(context.summary)
                if current != baseline {
                    return .success(
                        "Screen changed",
                        structuredContent: .object([
                            "passed": .bool(true),
                            "screen_token": .string(current),
                            "screen_summary": .string(context.summary)
                        ])
                    )
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        return ToolResult(
            content: "assert_screen_changed failed after \(timeoutMS)ms.",
            isError: true,
            structuredContent: .object(["passed": .bool(false), "screen_token": .string(baseline)])
        )
    }

    func preferredSelector(
        arguments: [String: String],
        includeDescription: Bool = false
    ) -> ElementSelector? {
        if let id = arguments["id"], !id.isEmpty {
            return ElementSelector(id: id)
        }
        if let label = arguments["label"], !label.isEmpty {
            return ElementSelector(label: label)
        }
        if let text = arguments["contains_text"], !text.isEmpty {
            return ElementSelector(containsText: text)
        }
        if includeDescription,
           let description = arguments["field_description"] ?? arguments["description"],
           !description.isEmpty {
            return ElementSelector(description: description)
        }
        return nil
    }

    func resolveElement(
        selector: ElementSelector,
        driver: any PlatformDriver,
        appID: String? = nil
    ) async throws -> ElementInfo? {
        if selector.description == nil {
            return try await driver.findElements(selector, appID: appID).first
        }
        guard let description = selector.description else { return nil }
        let all = try await filterAppRelevantElements(driver.findElements(ElementSelector(), appID: appID))
        if let exactID = all.first(where: { $0.id.caseInsensitiveCompare(description) == .orderedSame }) {
            return exactID
        }
        if let exactLabel = all.first(where: { $0.label.caseInsensitiveCompare(description) == .orderedSame }) {
            return exactLabel
        }
        return try await findFirstNavigableElement(query: description, driver: driver)
    }

    func screenToken(_ summary: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in summary.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    func executeAssertVisible(
        description: String,
        timeoutMS: Int,
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        let lowered = description.lowercased()
        var lastScreenSummary = ""
        repeat {
            if let context = try? await driver.getScreenContext() {
                lastScreenSummary = context.summary
            }
            if let match = try await findFirstNavigableElement(query: description, driver: driver) {
                return .success(
                    "Visible: '\(preferredElementName(label: match.label, id: match.id) ?? match.id)'",
                    structuredContent: .object([
                        "passed": .bool(true),
                        "element_id": .string(match.id),
                        "element_label": .string(match.label),
                        "element_type": .string(match.type?.rawValue ?? ""),
                        "screen_summary": .string(lastScreenSummary)
                    ])
                )
            }
            try? await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        return ToolResult(
            content: """
            assert_visible failed: no element matched '\(description)' within \(timeoutMS)ms.
            Current screen: \(lastScreenSummary)
            """,
            isError: true,
            structuredContent: .object([
                "passed": .bool(false),
                "query": .string(description),
                "query_lowercased": .string(lowered),
                "screen_summary": .string(lastScreenSummary)
            ])
        )
    }

    // MARK: - Intent tool helpers

    func findFirstNavigableElement(
        query: String,
        driver: any PlatformDriver
    ) async throws -> ElementInfo? {
        let lowered = query.lowercased()
        let allElements = try await driver.findElements(ElementSelector())
        let filtered = filterAppRelevantElements(allElements)
        if let match = filtered.first(where: {
            $0.label.lowercased().contains(lowered) || $0.id.lowercased().contains(lowered)
        }) {
            return match
        }
        let semantic = await (try? driver.findByDescription(query)) ?? []
        return semantic.first
    }

    func screenContextMatches(_ context: ScreenContext, query lowered: String) -> Bool {
        if context.summary.lowercased().contains(lowered) {
            return true
        }
        if let title = context.screenTitle, title.lowercased().contains(lowered) {
            return true
        }
        return false
    }
}
