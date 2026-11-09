import AmooCore
import MCP
import Tracing

/// What a caller expects the screen to show once a tap lands.
///
/// With one, `tap_element` waits for exactly that on the device instead of polling the whole
/// hierarchy for "anything changed", so a tap that did what was expected returns as soon as it
/// shows, and one that changes nothing visible costs no settle window.
struct TapExpectation: Equatable {
    var selector: ElementSelector
    /// Wait for the element to go away rather than to appear.
    var absent: Bool
    var timeoutMilliseconds: Int

    static let defaultTimeoutMilliseconds = 5000

    /// The expectation named by `expect_id`, `expect_label` or `expect_contains_text`, if any.
    static func parse(_ arguments: [String: String]) throws -> Self? {
        let id = arguments["expect_id"], label = arguments["expect_label"]
        let containsText = arguments["expect_contains_text"]
        let absent = boolArgument(arguments["expect_absent"]) ?? false
        guard id != nil || label != nil || containsText != nil else {
            if arguments["expect_absent"] != nil || arguments["expect_timeout_ms"] != nil {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "expect_absent and expect_timeout_ms need expect_id, expect_label or expect_contains_text."
                )
            }
            return nil
        }
        let timeout = arguments["expect_timeout_ms"].flatMap(Int.init) ?? defaultTimeoutMilliseconds
        guard (1 ... 120_000).contains(timeout) else {
            throw ToolExecutionError(
                code: "invalid_argument", message: "expect_timeout_ms must be between 1 and 120000."
            )
        }
        return Self(
            selector: ElementSelector(id: id, label: label, containsText: containsText),
            absent: absent,
            timeoutMilliseconds: timeout
        )
    }

    var summary: String {
        let name = selector.id ?? selector.label ?? selector.containsText ?? "element"
        return absent ? "'\(name)' to disappear" : "'\(name)' to appear"
    }
}

/// How an expectation resolved, reported as `expectation_status`.
enum TapExpectationStatus: String {
    case met
    case notMet = "not_met"
    /// An absence expectation whose element was already gone before the tap, so waiting proves nothing.
    case alreadySatisfied = "already_satisfied"
    case unverified

    /// The boolean for `expected_effect_met`; absent when the expectation cannot be judged.
    var effectMet: Bool? {
        switch self {
        case .met: true
        case .notMet: false
        case .alreadySatisfied, .unverified: nil
        }
    }
}

extension DriverToolExecutor {
    /// Whether an absence expectation's element is on screen right now.
    ///
    /// `nil` when it cannot be read, which leaves the expectation judged as before. Presence
    /// expectations need no pre-read: an element that was already there is the caller's choice.
    func expectationPresentBeforeTap(
        _ expectation: TapExpectation,
        driver: any PlatformDriver,
        appID: String?
    ) async -> Bool? {
        guard expectation.absent else { return nil }
        let selector = expectation.selector
        let found = await Self.withinBudget(milliseconds: 1500) {
            try? await driver.findElements(selector, appID: appID)
        }
        return found.map { !$0.isEmpty }
    }

    /// The result fields and note for a tap's expectation.
    func expectationOutcome(
        _ context: TapOutcomeContext,
        _ expectation: TapExpectation,
        driver: any PlatformDriver
    ) async -> (fields: [String: Value], note: String) {
        let status = await awaitExpectation(
            expectation, presentBeforeTap: context.expectationPresentBeforeTap, driver: driver
        )
        var fields: [String: Value] = ["expectation_status": .string(status.rawValue)]
        if let met = status.effectMet {
            fields["expected_effect_met"] = .bool(met)
        }
        return (fields, expectationNote(status, expectation))
    }

    /// Waits on the device for the expectation and classifies the outcome.
    func awaitExpectation(
        _ expectation: TapExpectation,
        presentBeforeTap: Bool? = nil,
        driver: any PlatformDriver
    ) async -> TapExpectationStatus {
        await (try? withSpan("tap.expect") { span in
            span.attributes["amoo.expectation.kind"] = expectation.absent ? "absent" : "present"
            let timeout = Duration(milliseconds: expectation.timeoutMilliseconds)
            do {
                if expectation.absent {
                    if presentBeforeTap == false {
                        span.attributes["amoo.expectation.already_satisfied"] = true
                        return TapExpectationStatus.alreadySatisfied
                    }
                    try await driver.waitForElementToDisappear(expectation.selector, timeout: timeout)
                } else {
                    try await driver.waitForElement(expectation.selector, timeout: timeout)
                }
                return TapExpectationStatus.met
            } catch AmooError.timeout {
                return TapExpectationStatus.notMet
            } catch {
                return TapExpectationStatus.unverified
            }
        }) ?? .unverified
    }

    func expectationNote(_ status: TapExpectationStatus, _ expectation: TapExpectation) -> String {
        switch status {
        case .met:
            "Expected \(expectation.summary): observed."
        case .notMet:
            "Expected \(expectation.summary) within \(expectation.timeoutMilliseconds)ms: not observed."
        case .alreadySatisfied:
            "Expected \(expectation.summary), but it was not on screen before the tap, so the tap cannot be credited."
                + " Inconclusive: expect an element the screen showed before the tap."
        case .unverified:
            "Expected \(expectation.summary): could not be checked on this driver."
        }
    }
}
