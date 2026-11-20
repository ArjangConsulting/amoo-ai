import AmooCore
import Foundation

/// `set_text` / `fill_field`: resolving the one text input, writing to it and confirming the value.
extension DriverToolExecutor {
    func executeSetText(
        selector: ElementSelector,
        value: String,
        driver: any PlatformDriver,
        appID: String? = nil,
        pick: ElementPick? = nil
    ) async throws -> ToolResult {
        let (resolved, siblings) = try await resolveTextInput(
            selector: selector, driver: driver, appID: appID, pick: pick
        )
        guard let matched = resolved else {
            return .error("set_text failed: no text field matched the selector")
        }
        guard matched.isVisible, matched.isEnabled else {
            return .error("set_text failed: matched field is not visible and enabled")
        }
        let credential = CredentialDispatch.fieldClass
        if credential == .secret, !matched.isSecureTextEntry {
            return ToolExecutionError(
                code: "credential_field_not_secure",
                message: "set_text refused: a secret credential only fills a secure text field, and "
                    + "[\(matched.id)] \(matched.label) is not one. Target the password field instead."
            ).result
        }
        let stableSelector = Self.writeSelector(for: matched, siblings: siblings, parent: selector.parentSelector)
        let before = matched.value ?? ""
        try await writeText(
            value,
            into: matched,
            before: before,
            selector: stableSelector,
            siblings: siblings,
            driver: driver,
            appID: appID
        )
        // A shared id cannot name the field again, so verification re-resolves the one text input.
        let reread = ElementSelector(
            id: matched.id.isEmpty ? nil : matched.id,
            label: stableSelector.label,
            parentSelector: selector.parentSelector
        )

        let mode = try await verifyWrittenText(
            value, in: matched, before: before, reread: reread, driver: driver, appID: appID
        )
        if mode == "cancelled" {
            return ToolExecutionError(code: "cancelled", message: "Operation cancelled.").result
        }
        let verified = mode == "exact"
        let filled = credential == nil ? "\(value.count) char(s)" : "a credential"
        var structured: [String: Value] = [
            "verified": .bool(verified),
            "verification_mode": .string(mode),
            "element_id": .string(matched.id),
            "element_label": .string(matched.label)
        ]
        if credential == nil {
            structured["value_length"] = .int(value.count)
        }
        return ToolResult(
            content: mode == "unverified"
                ? "set_text failed: field did not expose the requested value."
                : "Filled field [\(matched.id)] \(matched.label) with \(filled) (\(mode)).",
            isError: mode == "unverified",
            structuredContent: .object(structured)
        )
    }

    // Polls for up to three seconds until the field shows `value` (`exact`), or a secure field shows a
    // changed masked value (`masked_change`); `unverified` otherwise, `cancelled` when cancelled.
    // swiftlint:disable:next function_parameter_count
    func verifyWrittenText(
        _ value: String,
        in matched: ElementInfo,
        before: String,
        reread: ElementSelector,
        driver: any PlatformDriver,
        appID: String?
    ) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var mode = "unverified"
        repeat {
            if Task.isCancelled {
                return "cancelled"
            }
            try Task.checkCancellation()
            let updated = try await OperationDeadline.read(until: deadline) {
                try await self.resolveTextInput(selector: reread, driver: driver, appID: appID, pick: nil).0
            }
            if updated?.value == value {
                mode = "exact"
                break
            }
            if matched.isSecureTextEntry, let observed = updated?.value,
               !observed.isEmpty, observed != before, !value.isEmpty {
                mode = "masked_change"
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return mode
    }

    // Writes `value` into `matched`. When the device cannot tell the field apart from elements sharing its
    // identifier (its label is empty or shared too), it focuses the field at its own position, clears it
    // and types, as a tap with an index followed by type_text would.
    // swiftlint:disable:next function_parameter_count
    func writeText(
        _ value: String,
        into matched: ElementInfo,
        before: String,
        selector: ElementSelector,
        siblings: [ElementInfo],
        driver: any PlatformDriver,
        appID: String?
    ) async throws {
        let others = siblings.filter { $0 != matched && !matched.id.isEmpty && $0.id == matched.id }
        let ambiguous = !others.isEmpty && (selector.label == nil || others.contains { $0.label == matched.label })
        guard ambiguous, let point = matched.hitPoint ?? matched.frame?.centre else {
            try await driver.setText(selector, text: value, appID: appID)
            return
        }
        try await driver.tap(at: point)
        if !before.isEmpty {
            try await driver.clearText(characterCount: before.count)
        }
        try await driver.typeText(value)
    }

    /// The selector the device-side write uses for `matched`. When its id is shared (a SwiftUI search
    /// bar's magnifier carries the field's identifier), the field's own label narrows it to the input.
    nonisolated static func writeSelector(
        for matched: ElementInfo,
        siblings: [ElementInfo],
        parent: ParentSelector?
    ) -> ElementSelector {
        guard !matched.id.isEmpty else { return ElementSelector(label: matched.label, parentSelector: parent) }
        let sharedID = siblings.contains { $0.id == matched.id && $0 != matched }
        return ElementSelector(
            id: matched.id,
            label: sharedID && !matched.label.isEmpty ? matched.label : nil,
            parentSelector: parent
        )
    }

    /// The element `set_text` / `fill_field` writes to, and every element the selector matched. When a
    /// selector matches several elements of which exactly one is a text input, the input is the target
    /// without needing `index`: a SwiftUI search bar's magnifier image inherits the field's identifier.
    func resolveTextInput(
        selector: ElementSelector,
        driver: any PlatformDriver,
        appID: String?,
        pick: ElementPick?
    ) async throws -> (ElementInfo?, [ElementInfo]) {
        guard selector.description == nil else {
            return try await (resolveElement(selector: selector, driver: driver, appID: appID, pick: pick), [])
        }
        let all = try await validateGeometry(findScopedElements(selector, driver: driver, appID: appID))
        let inputs = all.filter { $0.type == .textField }
        let candidates = pick == nil && all.count > 1 && inputs.count == 1 ? inputs : all
        return try (pickElement(candidates, pick: pick), all)
    }
}
