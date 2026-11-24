import AmooCore

extension DriverToolExecutor {
    /// A read that failed because of the moment it ran, not one that cannot succeed: a capture past
    /// the companion's walk limit, a query RPC past its deadline, or an Android capture that raced a
    /// tree still changing (text streaming in) after the companion's own quick retries. The depth and
    /// node limits are properties of the tree, so they are not retried.
    static func isTransientCapture(_ error: any Error) -> Bool {
        let text = String(describing: error)
        if text.contains("RPC timed out before completing")
            || text.contains("Accessibility hierarchy changed during capture") {
            return true
        }
        return text.contains("Hierarchy capture incomplete")
            && !text.contains("depth limit") && !text.contains("node limit")
    }

    /// Waits briefly before the next poll and returns the error to report if none completes.
    ///
    /// An animating screen (an endless shimmer) can slow one capture past the companion's walk
    /// limit while the next one completes, so the caller's `timeout_ms` decides when to stop.
    static func pauseAfterTransientCapture(_ error: any Error, deadline: ContinuousClock.Instant) async -> String {
        try? await Task.sleep(until: min(deadline, .now + .milliseconds(200)), clock: .continuous)
        return String(describing: error)
    }

    func executeAssertVisible(
        description: String,
        timeoutMS: Int,
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let deadline = ContinuousClock.now + .milliseconds(max(1, timeoutMS))
        let lowered = description.lowercased()
        var lastScreenSummary = ""
        repeat {
            if Task.isCancelled {
                return ToolExecutionError(code: "cancelled", message: "Operation cancelled.").result
            }
            if let context = try? await OperationDeadline.read(
                until: deadline,
                operation: { try await driver.getScreenContext() }
            ) {
                lastScreenSummary = context.summary
            }
            if let match = try await OperationDeadline.read(until: deadline, operation: {
                try await self.findFirstNavigableElement(query: description, driver: driver)
            }) {
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
            try? await Task.sleep(until: min(deadline, .now + .milliseconds(500)), clock: .continuous)
        } while ContinuousClock.now < deadline
        return ToolResult(
            content: """
            assert_visible failed: no element matched '\(description)' within \(timeoutMS)ms.
            Current screen: \(lastScreenSummary)
            """,
            isError: true,
            structuredContent: .object([
                "passed": .bool(false),
                "failure_kind": .string("assertion_mismatch"),
                "query": .string(description),
                "query_lowercased": .string(lowered),
                "screen_summary": .string(lastScreenSummary)
            ])
        )
    }
}
