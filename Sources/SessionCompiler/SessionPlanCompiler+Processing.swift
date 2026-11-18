import AmooCore
import Foundation
import StudioProtocol
import TestSession

extension SessionPlanCompiler {
    /// Throws when the recorded session names a platform that is neither iOS nor Android. A session
    /// is written by our own recorder, so that means a corrupt or hand-edited report — guessing a
    /// platform there would generate a test for the wrong OS.
    /// Runs `process` over the actions the retry pass kept, giving each one its retry context.
    ///
    /// `next` deliberately skips suppressed actions: the pre-transition inspection heuristic asks
    /// "what happens after this?", and a suppressed duplicate tap is not a distinct next step.
    static func processActions(
        _ actions: [SessionAction],
        retries: RetryAnalysis,
        interval: TimeInterval,
        appID: String,
        platform: Platform,
        session: SessionLaunch = SessionLaunch()
    ) -> [ProcessedAction] {
        let gapsByIndex = Dictionary(
            uniqueKeysWithValues: retries.observations.map { ($0.actionIndex, $0.gaps) }
        )
        func nextAction(after offset: Int) -> SessionAction? {
            var cursor = offset + 1
            while cursor < actions.count {
                if !retries.suppressed.contains(cursor) {
                    return actions[cursor]
                }
                cursor += 1
            }
            return nil
        }

        var pairedLaunch: Int?
        var processed: [ProcessedAction] = []
        var recentElements: [RecordedElement] = []
        processed.reserveCapacity(actions.count)
        for (offset, action) in actions.enumerated() where !retries.suppressed.contains(offset) {
            if pairedLaunch == offset {
                continue
            }
            if action.observedElements.isEmpty == false {
                recentElements = action.observedElements
            } else if action.toolName == "find_elements" {
                recentElements = legacyRecordedElements(from: action.result)
            }
            // A raw `swipe` is a touch swipe on a phone but a mouse drag on a Mac, and a drag is not
            // a scroll. Turning it into `swipe_in_direction` would replay as a wheel scroll, so on a
            // Mac it stays a coordinate gesture and is reported as excluded.
            let swipeResolved = platform == .macos
                ? action
                : semanticCoordinateSwipe(action, recentElements: recentElements)
            var effectiveAction = attachObservedLabel(
                attachGestureTargetLabel(swipeResolved, recentElements: recentElements),
                recentElements: recentElements
            )
            if let relaunch = relaunchAction(
                at: offset,
                in: actions,
                appID: appID,
                platform: platform,
                session: session
            ) {
                pairedLaunch = action.toolName == "device_terminate_app" ? offset + 1 : pairedLaunch
                effectiveAction = relaunch
                recentElements = []
            }
            processed.append(process(
                index: offset,
                action: effectiveAction,
                next: nextAction(after: offset),
                retry: RetryContext(
                    count: retries.counts[offset] ?? 1,
                    interval: interval,
                    gaps: gapsByIndex[offset] ?? []
                )
            ))
            if invalidatesRecordedGeometry(action.toolName) {
                recentElements = []
            }
        }
        return processed
    }

    /// The `relaunch_application` that the action at `offset` (with the next one, for a
    /// terminate/launch pair) amounts to, or `nil` when it is not a relaunch of the session's launch.
    /// A launch alone counts only where launching replaces a running process (simctl's
    /// `--terminate-running-process`, devicectl's `--terminate-existing`); Android may resume it.
    static func relaunchAction(
        at offset: Int,
        in actions: [SessionAction],
        appID: String,
        platform: Platform,
        session: SessionLaunch
    ) -> SessionAction? {
        let action = actions[offset]
        let dropped: [String]? = if offset + 1 < actions.count, action.toolName == "device_terminate_app" {
            safeRelaunch(action, actions[offset + 1], appID: appID, session: session)
        } else if platform != .android {
            relaunchingLaunch(action, appID: appID, session: session)
        } else {
            nil
        }
        guard let dropped else { return nil }
        return SessionAction(
            timestamp: action.timestamp,
            toolName: StudioTool.relaunchApplication.rawValue,
            arguments: dropped.isEmpty ? [:] : [relaunchDroppedEnvironmentArgument: dropped.joined(separator: ",")],
            result: action.result,
            isError: false
        )
    }

    /// The launch configuration the session started with, which a later launch is compared against.
    struct SessionLaunch {
        var arguments: [String] = []
        var environment: [String: String] = [:]
    }

    /// The `relaunch_application` argument naming the environment keys a relaunch left out of the
    /// session's launch, comma-separated. Generation accepts it only when the context declares each
    /// key a state reset (`relaunchResetEnvironmentKeys`).
    static let relaunchDroppedEnvironmentArgument = "without_environment"

    /// The environment keys a successful, adjacent terminate/launch pair for the session app leaves
    /// out, or `nil` when the pair is not a relaunch of the same configuration. Other lifecycle calls
    /// remain excluded for explicit review.
    static func safeRelaunch(
        _ terminate: SessionAction,
        _ launch: SessionAction,
        appID: String,
        session: SessionLaunch = SessionLaunch()
    ) -> [String]? {
        let allowed: Set = ["app_id", "session_id", "device_id", "timeout_ms"]
        guard !appID.isEmpty, terminate.toolName == "device_terminate_app", !terminate.isError,
              terminate.intent == .testStep, terminate.arguments["app_id"] == appID,
              Set(terminate.arguments.keys).isSubset(of: allowed)
        else { return nil }
        return relaunchingLaunch(launch, appID: appID, session: session)
    }

    /// The environment keys a successful launch of the session app leaves out of the session's own
    /// launch, or `nil` when it is not a relaunch of that configuration: different arguments, a key
    /// with a different value, or one the session never set. A launch without overrides drops none.
    static func relaunchingLaunch(_ launch: SessionAction, appID: String, session: SessionLaunch) -> [String]? {
        let allowed: Set = ["app_id", "session_id", "device_id", "timeout_ms", "launch_args", "environment"]
        guard !appID.isEmpty, launch.toolName == "device_launch_app", !launch.isError,
              launch.intent == .testStep, launch.arguments["app_id"] == appID,
              Set(launch.arguments.keys).isSubset(of: allowed)
        else { return nil }
        if let raw = launch.arguments["launch_args"],
           raw.split(separator: ",").map(String.init) != session.arguments {
            return nil
        }
        guard let raw = launch.arguments["environment"] else { return [] }
        let environment = Dictionary(
            raw.split(separator: ",").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            },
            uniquingKeysWith: { _, last in last }
        )
        guard environment.allSatisfy({ session.environment[$0.key] == $0.value }) else { return nil }
        return session.environment.keys.filter { environment[$0] == nil }.sorted()
    }
}
