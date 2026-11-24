import AmooCore
import AmooLogging
import ProcessRunner

private let logger = AmooLogger.forType(GestureNotSent.self)

/// An error raised before a gesture was sent, so the caller knows nothing reached the device and a
/// retry is safe. It reads as the error it wraps.
struct GestureNotSent: Error, CustomStringConvertible {
    let underlying: any Error

    var description: String {
        "\(underlying)"
    }
}

extension DriverToolExecutor {
    /// The result for an unexpected error, marked `not_dispatched` when it was raised before the
    /// gesture was sent.
    func failureResult(toolName: String, error: any Error, arguments: [String: String]) async -> ToolResult {
        var result = await ToolResult.error(failureMessage(toolName: toolName, error: error, arguments: arguments))
        if error is GestureNotSent {
            result.structuredContent = .object(["dispatch_status": .string("not_dispatched")])
        }
        return result
    }

    /// What `tap_element` taps and how it checks it.
    struct TapRequest {
        var selector: ElementSelector
        var pick: ElementPick?
        var checks: TapChecks
        var arguments: [String: String]
        var appID: String?
    }

    /// What `tap_element` read before it taps: the settled target, the preflight checks and the app in
    /// front, or the result that refuses the tap.
    enum PreparedTap {
        case ready(matched: ElementInfo, preflight: TapPreflight, foreground: String?)
        case refused(ToolResult)
    }

    /// Runs `body`, the part of a gesture tool that only reads, and marks any failure in it as
    /// raised before the gesture was sent. A ``ToolExecutionError`` already says what happened, and a
    /// device that stopped answering is reported as such.
    func beforeGesture<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ToolExecutionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProcessRunnerError where error.isDeviceFailure {
            throw error
        } catch is OperationDeadline.DeadlineExceeded {
            throw ToolExecutionError(
                code: "deadline_exceeded",
                message: "Operation exceeded its time budget before the gesture was sent.",
                extra: ["dispatch_status": .string("not_dispatched")]
            )
        } catch {
            throw GestureNotSent(underlying: error)
        }
    }

    /// Resolves, checks and settles `tap_element`'s target, or returns the result that refuses it.
    ///
    /// Every step only reads. On Android a read taken while the tree is still changing (text
    /// streaming in) can fail with "Accessibility hierarchy changed during capture" after the
    /// companion's own quick retries; such a read is retried until the call's deadline
    /// (`timeout_ms`, else 5 seconds), like an assertion's.
    func preparedTap(_ request: TapRequest, driver: any PlatformDriver) async throws -> PreparedTap {
        let timeout = request.arguments["timeout_ms"].flatMap(Int.init) ?? 5000
        let deadline = ContinuousClock.now + .milliseconds(max(1, timeout))
        while true {
            do {
                return try await preparedTapOnce(request, driver: driver)
            } catch where Self.isTransientCapture(error) && ContinuousClock.now < deadline {
                logger.debug("Retrying tap preparation after a transient capture: tool=tap_element")
                _ = await Self.pauseAfterTransientCapture(error, deadline: deadline)
            }
        }
    }

    private func preparedTapOnce(_ request: TapRequest, driver: any PlatformDriver) async throws -> PreparedTap {
        let (selector, pick, appID) = (request.selector, request.pick, request.appID)
        let target = try await resolveTapTarget(
            selector,
            pick: pick,
            arguments: request.arguments,
            driver: driver,
            appID: appID
        )
        guard let matched = target else {
            throw ToolExecutionError(
                code: "element_not_found",
                message: "tap_element failed: no element matched the selector",
                extra: ["dispatch_status": .string("not_dispatched"), "failure_kind": .string("selector_miss")]
            )
        }
        guard matched.isVisible, matched.isEnabled else {
            return .refused(.error("tap_element failed: matched element is not visible and enabled"))
        }
        // Independent of the preflight hierarchy read, so it overlaps it instead of adding a round trip.
        async let foregroundRead = try? await driver.currentApp().bundleID
        let preflight = try await tapPreflight(
            matched: matched,
            point: matched.hitPoint ?? matched.frame.map(\.centre),
            checks: request.checks,
            driver: driver,
            appID: appID
        )
        if let refusal = preflight.refusal {
            return .refused(refusal)
        }
        let settled = try await settledElement(matched, hierarchy: preflight.hierarchy) {
            try await resolveElement(selector: selector, driver: driver, appID: appID, pick: pick)
        }
        return await .ready(matched: settled, preflight: preflight, foreground: foregroundRead)
    }
}
