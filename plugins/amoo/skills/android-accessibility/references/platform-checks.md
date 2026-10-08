# Android evidence and remediation

Read sections for enabled rules. Native semantics, app-owned tests, external node trees and
TalkBack behavior have different coverage; preserve the source of each observation.

## Font scaling

Run the same task at actual baseline and requested larger font settings. Include compact
screens, keyboard/form errors, dialogs and scrolling to necessary actions. Verify rendering
changed, not just the settings value. Android 14+ supports nonlinear scaling; multiplying a
font by `fontScale` is not an accurate universal measurement.
[Android font scaling](https://developer.android.com/about/versions/14/features#font-scaling).

Use `sp` for text and platform-aware sizing; Compose typography should respect user settings.
Avoid fixed-height containers, unnecessary `maxLines`, or smaller text as the only way to keep
content visible. Do not scale padding by treating a font-scale multiplier as density. Record
loss of information/function and intentional exceptions; a larger setting alone cannot prove
a WCAG resizing result.
[Resize Text](https://www.w3.org/WAI/WCAG22/Understanding/resize-text.html).

## Names, input instructions and roles

Text controls often get names from visible text, associated labels or hints; requiring a
`contentDescription` on every control creates noise and can hide useful text. Name meaningful
non-text content, keep decorative images silent, associate input labels, and preserve relevant
visible wording. Resource IDs/test tags identify elements for tests, not for users.
[Android naming principles](https://developer.android.com/guide/topics/ui/accessibility/principles),
[Name, Role, Value](https://www.w3.org/WAI/WCAG22/Understanding/name-role-value.html).

Android hint text, action labels and state descriptions are different from UIKit hints. Keep
persistent input purpose and necessary instructions discoverable after entry; a disappearing
placeholder may be insufficient in context. Do not prepend roles or TalkBack gesture commands
to every label. Absence of one property is not absence of the computed accessible name.
[Labels or Instructions](https://www.w3.org/WAI/WCAG22/Understanding/labels-or-instructions.html).

Prefer built-in View/Compose/Material controls with correct role and interaction semantics.
For custom components, verify role, checked/selected/disabled state, value/range and actions.
Compose can expose `stateDescription`, heading, progress and collection semantics; avoid
duplicating state in a content description without verifying what TalkBack announces.
[Compose semantics](https://developer.android.com/develop/ui/compose/accessibility/semantics).
Public node support varies by API/library/backend; an external tree is not every Compose
property or View attribute. Preserve raw text/content description and label relationships
where available; classify unavailable metadata as missing coverage.

## Traversal, focus and grouping

Observe forward/backward TalkBack navigation through meaningful content and actions. Check
modal entry/isolation, dismissal recovery, dynamic insertion, errors and RTL when in scope.
Geometry or tree order can suggest a problem but cannot prove TalkBack traversal. Keyboard
focus APIs test input focus; they do not automatically set accessibility focus.
[Meaningful Sequence](https://www.w3.org/WAI/WCAG22/Understanding/meaningful-sequence.html),
[Focus Order](https://www.w3.org/WAI/WCAG22/Understanding/focus-order.html).

Use natural semantics order first. For demonstrated problems, inspect View traversal
relationships or Compose `isTraversalGroup`/`traversalIndex` in context; don't sort every
element manually or assume these control keyboard focus.
[Compose traversal](https://developer.android.com/develop/ui/compose/accessibility/traversal).

Combine coherent read-only information, while preserving independent actions. Compose
`mergeDescendants` and `clearAndSetSemantics` have different effects; nested clickable nodes
may stay separate. Clearing semantics requires equivalent replacements. Test both relevant
merged and unmerged semantics in app-owned tests and actual TalkBack behavior when available.
On Views, inspect parent/child accessibility importance and grouping without suppressing
useful child controls. Do not hide controls just to reduce the number of stops.
[Merging and clearing](https://developer.android.com/develop/ui/compose/accessibility/merging-clearing),
[Info and Relationships](https://www.w3.org/WAI/WCAG22/Understanding/info-and-relationships.html).

## Providers and service coexistence

Espresso accessibility checks and Compose accessibility integration run in app tests.
ATF also accepts accessibility nodes/windows, so a cross-app companion route is plausible but
needs per-check qualification with a pinned released library. View-based rendering data and
node-based coverage can differ; inability to run a check is not a clean result.
[Espresso checks](https://developer.android.com/training/testing/espresso/accessibility-checking),
[Compose checks](https://developer.android.com/develop/ui/compose/accessibility/testing),
[ATF node/window builders](https://github.com/google/Accessibility-Test-Framework-for-Android/blob/master/src/main/java/com/google/android/apps/common/testing/accessibility/framework/uielement/AccessibilityHierarchyAndroid.java).

Before UiAutomation/UiAutomator connects, qualify
`FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES` consistently. Existing amoo bridge code uses the
default acquisition; do not claim TalkBack remains active without checking during inspection
and actions. Don't open a second UI-automation owner to work around an empty hierarchy.
[UiAutomation](https://developer.android.com/reference/android/app/UiAutomation#FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES),
[UiAutomator flags](https://developer.android.com/reference/androidx/test/uiautomator/Configurator#setUiAutomationFlags(int)).

TalkBack utterances are not provided by ordinary node text or generic accessibility events.
Use a qualified speech route or human-supplied evidence; otherwise keep speech verification
pending. Live regions/source announcements can identify intent, not prove what a user heard.
Never hard-code a TalkBack component or clear `enabled_accessibility_services` for cleanup.

For extended checks, report small-node bounds in pixels/dp with captured density, not iOS
points. Android's 48 dp platform recommendation does not automatically establish a WCAG
failure; actual touch delegates/hit regions can be larger than bounds. Distinguish measured
contrast findings from image estimates and verify announcements across transitions.
[Android touch targets](https://support.google.com/accessibility/android/answer/7101858).

## Example evidence-backed tag

```yaml
ruleID: A11Y-ORDER-FOCUS
ruleVersion: "1"
source: llmReview
status: needsReview
impactSeverity: medium
effectiveSeverity: medium
confidence: 0.6
stateID: checkout.error
elementID: null
evidenceRefs: [artifacts/checkout-tree.json, source/Checkout.kt:81]
observation: Error semantics are inserted after the primary action in the supplied tree.
inference: The error may be encountered late; actual TalkBack traversal is unknown.
mapping: "1.3.2 A candidate; confirm whether meaning or task operation is affected."
fix: Preserve input/error association and verify useful error discovery.
verificationNeeded: Observe TalkBack order and feedback during invalid submission.
```
