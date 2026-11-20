import AmooCore

extension DriverToolExecutor {
    /// How long the first read after a launch may take, whatever the step's own timeout.
    static let firstReadAfterLaunchMilliseconds = 10000

    /// The deadline for a read: `deadline`, or the launch budget when it is the first read since a
    /// verified launch.
    ///
    /// XCUITest's first snapshot of a freshly launched app waits for it to go idle, which took 3 to
    /// 5 seconds on Jot. That wait landed inside the next step's own timeout, and about one run in
    /// ten crossed it and failed on a screen that was already there. Probing at launch paid the same
    /// wait plus a second query; giving the step that needs the first read room for it pays it once.
    func firstReadDeadline(_ deadline: ContinuousClock.Instant) -> ContinuousClock.Instant {
        guard awaitingFirstReadAfterLaunch else { return deadline }
        return max(deadline, .now + .milliseconds(Self.firstReadAfterLaunchMilliseconds))
    }

    /// Records that a read completed, so later reads keep their own deadlines.
    func noteReadCompleted() {
        awaitingFirstReadAfterLaunch = false
    }

    /// How long `tap_element` keeps looking for a target that is not there yet, when the call sets
    /// no `timeout_ms`.
    static let tapAppearanceGraceMilliseconds = 2000

    /// The element `tap_element` should tap: polled until it is visible and enabled, for the call's
    /// `timeout_ms` or a two-second grace, within the call's deadline (`timeout_ms`, else 5 seconds).
    /// A screen marker can appear a moment before the controls inside it (Jot's day-detail habit
    /// picker), so the first miss is not proof the control is absent. An ambiguous selector still
    /// fails at once. Returns the last match, which may be hidden or disabled, or `nil` when nothing
    /// ever matched.
    func resolveTapTarget(
        _ selector: ElementSelector,
        pick: ElementPick?,
        arguments: [String: String],
        driver: any PlatformDriver,
        appID: String?
    ) async throws -> ElementInfo? {
        let timeout = arguments["timeout_ms"].flatMap(Int.init)
        let deadline = ContinuousClock.now + .milliseconds(max(1, timeout ?? 5000))
        let grace = timeout ?? Self.tapAppearanceGraceMilliseconds
        let lookUntil = min(deadline, ContinuousClock.now + .milliseconds(max(0, grace)))
        while true {
            let matched = try await OperationDeadline.read(until: firstReadDeadline(deadline)) {
                try await self.resolveElement(selector: selector, driver: driver, appID: appID, pick: pick)
            }
            noteReadCompleted()
            if let matched, matched.isVisible, matched.isEnabled {
                return matched
            }
            guard ContinuousClock.now + .milliseconds(200) < lookUntil else { return matched }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}
