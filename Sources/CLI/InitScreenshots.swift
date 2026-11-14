import Foundation
import StudioProtocol
import SwiftyTerminal

/// The screenshot sizes guided init offers, as a fraction of one pixel per point.
private let initScreenshotScales: [(scale: Double, label: String)] = [
    (1, "Standard: 1 pixel per point (402×874 on a 3x iPhone)"),
    (0.5, "Half: 201×437, about a quarter of the image tokens"),
    (0.25, "Quarter: 101×219, about a sixteenth of the image tokens; small text may be unreadable")
]

/// The project's screenshot defaults with any `--screenshot-*` flags applied, or nil when none was passed.
func initScreenshotPolicy(_ request: InitRequest, current: ScreenshotPolicy) -> ScreenshotPolicy? {
    guard request.screenshotScale != nil || request.screenshotInline != nil else { return nil }
    return ScreenshotPolicy(
        scale: request.screenshotScale ?? current.scale,
        returnImage: request.screenshotInline ?? current.returnImage
    )
}

/// Applies `--screenshot-*` flags, or asks in a guided run without `--yes`, and saves a changed policy.
/// A guided run hears the outcome now; a plain-text headless run gets it back to print. `--json`
/// prints one document, so it gets nothing.
func settleInitScreenshots(
    _ request: InitRequest,
    interactive: Bool,
    root: URL,
    prompter: any Prompting
) -> String? {
    let current = ScreenshotPolicy.resolve(from: root)
    let flagged = initScreenshotPolicy(request, current: current)
    let asked = interactive && !request.assumeYes && flagged == nil
    guard let chosen = asked ? askInitScreenshotPolicy(current: current, prompter: prompter) : flagged,
          let note = applyInitScreenshotPolicy(chosen, current: current, root: root) else { return nil }
    if interactive {
        prompter.say(note)
        return nil
    }
    return request.json ? nil : note
}

extension CLIResult {
    /// The result with `note` on a line of its own after the output, unchanged without one.
    func appendingNote(_ note: String?) -> Self {
        guard let note else { return self }
        return Self(output: output.isEmpty ? note : output + "\n" + note, exitCode: exitCode)
    }
}

/// Asks for the screenshot size and delivery, starting from the project's current choice. A cancelled
/// question keeps that part as it was, since neither choice touches a device.
func askInitScreenshotPolicy(current: ScreenshotPolicy, prompter: any Prompting) -> ScreenshotPolicy {
    prompter.say("""

    Screenshots
    Agents always save screenshots to a file. Smaller images and path-only delivery make each
    capture faster to read and cheaper in tokens; an agent can still ask for a larger or inline image.
    """)
    let scaleDefault = initScreenshotScales.firstIndex { $0.scale == current.scale } ?? 0
    let scale = prompter.choose(
        "Screenshot size",
        options: initScreenshotScales.map(\.label),
        default: scaleDefault
    ).map { initScreenshotScales[$0].scale } ?? current.scale
    let delivery = prompter.choose(
        "How should agents receive screenshots?",
        options: [
            "File path only: the agent opens the file when it needs pixels (recommended)",
            "Inline image too: every capture costs image tokens on that turn and every later one"
        ],
        default: current.returnImage ? 1 : 0
    ).map { $0 == 1 } ?? current.returnImage
    return ScreenshotPolicy(scale: scale, returnImage: delivery)
}

/// Writes `policy` to the project's `amoo.config.json` when it differs from what is in effect, and
/// describes the outcome. Nothing is written for an unchanged policy.
func applyInitScreenshotPolicy(_ policy: ScreenshotPolicy, current: ScreenshotPolicy, root: URL) -> String? {
    guard policy != current else { return nil }
    if let problem = policy.validationProblems().first {
        return "Screenshot settings not saved: \(problem)."
    }
    let file = AmooProjectConfig.discover(from: root) ?? AmooProjectConfig.defaultLocation(from: root)
    do {
        try AmooProjectConfig.writeScreenshotPolicy(policy, to: file)
        return "Saved screenshot settings (\(describeScreenshotPolicy(policy))) to \(file.path)."
    } catch {
        return "Screenshot settings not saved to \(file.path): \(error)"
    }
}

func describeScreenshotPolicy(_ policy: ScreenshotPolicy) -> String {
    let size = policy.scale == 1 ? "1 pixel per point" : "\(policy.scale.formatted()) × 1 pixel per point"
    return size + (policy.returnImage ? ", returned inline" : ", file path only")
}

/// The line in the managed `## amoo init` block, so agents know what a capture costs here.
func screenshotsAgentsLine(_ policy: ScreenshotPolicy) -> String {
    "- Screenshots: \(describeScreenshotPolicy(policy)), set in `\(AmooProjectConfig.fileName)`"
        + " (`amoo init` to change). Batch independent assertions in one `run_steps`."
}
