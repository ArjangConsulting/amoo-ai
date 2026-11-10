import StudioProtocol

/// The displayed-wait statements, standalone and shared modes. The shared library's
/// `waitUntilDisplayed` already performs the wait on the root view, so the call stands alone.
extension EspressoEmitter {
    static func displayedWait(
        _ target: String,
        for operation: StudioToolOperation,
        shared: Bool
    ) throws -> String {
        try displayedWait(target, timeout: timeoutMilliseconds(for: operation), shared: shared)
    }

    static func displayedWait(_ target: String, timeout: Int64, shared: Bool) -> String {
        shared
            ? "waitUntilDisplayed(\(target), \(timeout)L)"
            : "onView(isRoot()).perform(waitUntilDisplayed(\(target), \(timeout)L))"
    }

    static func notDisplayedWait(_ target: String, timeout: Int64, shared: Bool) -> String {
        shared
            ? "waitUntilNotDisplayed(\(target), \(timeout)L)"
            : "onView(isRoot()).perform(waitUntilNotDisplayed(\(target), \(timeout)L))"
    }
}
