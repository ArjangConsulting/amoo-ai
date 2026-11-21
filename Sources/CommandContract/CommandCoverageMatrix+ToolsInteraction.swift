// swiftlint:disable multiline_arguments
import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    /// Scrolling and keyboard helpers, native video, plus the selected-state assertion. Split from `+Tools.swift` to
    /// keep that file
    /// under the length limit.
    static let toolInteractionCommands: [CommandCoverage] = [
        .init(
            name: "record_video", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .home,
            expectedAssertion: "a non-empty native video is saved to output"
        ),
        .init(
            name: "start_recording", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .home,
            expectedAssertion: "a native recording starts and survives the calling process"
        ),
        .init(
            name: "stop_recording", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .home,
            expectedAssertion: "the running recording is saved with its recorded length"
        ),
        .init(
            name: "get_capabilities", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .environment,
            expectedAssertion: "installed schemas, binary identity and provider assertion support are queryable"
        ),
        .init(
            name: "get_run_telemetry", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .environment,
            expectedAssertion: "Counts failed, unfinished and completed requests across a caller run UUID."
        ),
        .init(
            name: "get_verification_report", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .home,
            expectedAssertion: "every required check retains outcome, reason and evidence; status is derived"
        ),
        .init(
            name: "drag",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .gesture,
            expectedAssertion: "dragging the gesture lab's drag source onto its drop zone reports the drop"
        ),
        .init(
            name: "pinch",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .blocking,
            platforms: allPlatforms,
            fixtureScreen: .gesture,
            expectedAssertion: "pinching the gesture lab's zoom target out and in changes its reported scale"
        ),
        .init(
            name: "device_health", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: allPlatforms, fixtureScreen: .home,
            expectedAssertion: "independent transport probes distinguish connectivity from app semantic readiness"
        ),
        .init(
            name: "assert_checked", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: [.android], fixtureScreen: .home,
            expectedAssertion: "an existing checkable control's checked property equals expected"
        ),
        .init(
            name: "assert_state_description", channel: .tool, kind: .deterministic, releaseTier: .informational,
            platforms: [.android], fixtureScreen: .home,
            expectedAssertion: "native state description matches independently of text/value"
        ),
        .init(
            name: "assert_selected",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "an existing element's selected state equals expected; an absent element fails"
        ),
        .init(
            name: "scroll_to_element",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "details list scrolls an off-screen fixture row into view"
        ),
        .init(
            name: "dismiss_keyboard",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .details,
            expectedAssertion: "keyboard hides after dismissing it from a focused field"
        )
    ]
}

// swiftlint:enable multiline_arguments
