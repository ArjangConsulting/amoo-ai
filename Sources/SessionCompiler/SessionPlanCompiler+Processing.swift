import Foundation
import StudioProtocol
import TestSession

// swiftlint:disable multiline_arguments

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
        appID: String
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
            var effectiveAction = attachObservedLabel(
                attachGestureTargetLabel(
                    semanticCoordinateSwipe(action, recentElements: recentElements),
                    recentElements: recentElements
                ),
                recentElements: recentElements
            )
            if offset + 1 < actions.count, safeRelaunch(action, actions[offset + 1], appID: appID) {
                pairedLaunch = offset + 1
                effectiveAction = SessionAction(
                    timestamp: action.timestamp, toolName: StudioTool.relaunchApplication.rawValue,
                    arguments: [:], result: action.result, isError: false
                )
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

    /// Collapse only an adjacent successful terminate/launch pair for the session app, with no
    /// launch overrides. Other lifecycle calls remain excluded for explicit review.
    static func safeRelaunch(_ terminate: SessionAction, _ launch: SessionAction, appID: String) -> Bool {
        let allowed: Set = ["app_id", "session_id", "device_id", "timeout_ms"]
        return !appID.isEmpty && terminate.toolName == "device_terminate_app"
            && launch.toolName == "device_launch_app" && !terminate.isError && !launch.isError
            && terminate.intent == .testStep && launch.intent == .testStep
            && terminate.arguments["app_id"] == appID && launch.arguments["app_id"] == appID
            && Set(terminate.arguments.keys).isSubset(of: allowed)
            && Set(launch.arguments.keys).isSubset(of: allowed)
    }
}

// swiftlint:enable multiline_arguments
