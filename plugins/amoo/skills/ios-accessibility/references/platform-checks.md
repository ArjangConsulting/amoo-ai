# iOS evidence and remediation

Use only the sections for enabled rules. These checks combine platform best practices and
conditional WCAG mappings; missing a particular SwiftUI modifier is not itself a violation.

## Text scaling

Compare the same task at observed baseline and requested larger accessibility sizes. Verify
text actually changes, full information remains available, buttons are reachable after scroll,
and keyboards, sheets, compact screens and landscape do not obscure necessary actions.
Screenshots alone do not prove the precise scaling ratio or an accessible alternative.
Disabling this rule should leave other semantics checks active.

For source fixes, prefer semantic SwiftUI fonts and adaptive layouts; use `@ScaledMetric` for
appropriate custom dimensions. UIKit can use preferred text styles or `UIFontMetrics` and
`adjustsFontForContentSizeCategory`. Avoid fixed-height text containers, excessive line limits
and shrinking text as the only escape from clipping. Check intentional exceptions in context.
[Apple font scaling](https://developer.apple.com/documentation/uikit/scaling-fonts-automatically).
For a criterion finding, establish actual resizing and content/function loss; a test at the
largest category is useful evidence but not a direct 200% measurement.
[Resize Text](https://www.w3.org/WAI/WCAG22/Understanding/resize-text.html).

## Names, values and hints

Prefer a native Button/Toggle/TextField with meaningful localized content. Icon-only actions
need a meaningful accessible name; decorative content should not add noise. Repeated “Delete”
actions may need item context; do not require every label to be globally unique. Match names
to visible wording where relevant, distinguish a control's name from its current value, and
never use `accessibilityIdentifier` to satisfy a naming requirement.
[Name, Role, Value](https://www.w3.org/WAI/WCAG22/Understanding/name-role-value.html).

UIKit `accessibilityHint` and SwiftUI `.accessibilityHint` explain a non-obvious outcome.
Do not add “double tap” or repeat the name/role everywhere. Obvious actions may need no hint.
No hint in an external tree, no hint spoken because hints are disabled, and a genuinely missing
necessary instruction are different observations. amoo currently cannot export arbitrary raw
hints; inspect app source or an opt-in adapter. Record VoiceOver hint settings when supplied.
[Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[Labels or Instructions](https://www.w3.org/WAI/WCAG22/Understanding/labels-or-instructions.html).

## Traits and actions

Verify role, heading, selected/disabled state and changing values reflect behavior. Prefer
native controls over a Text with a tap gesture. Use UIKit traits or SwiftUI add/remove-traits
modifiers for custom elements; do not redundantly speak “button” or “selected” in labels without
observing whether the system duplicates it. Keep custom-renderer compatibility when changing
labels. Adjustable controls need usable adjustments and current-value feedback.

XCUITest element type is partial role evidence, not complete raw traits. `isSelected` and
`hasFocus` availability does not prove the companion exports them, and input focus is not
VoiceOver focus. Source metadata establishes intent; confirm actual user behavior when possible.
[Apple element attributes](https://developer.apple.com/documentation/xcuiautomation/xcuielementattributes).

## Order, focus and grouping

Walk forward and backward through representative content, including RTL and offscreen items
when in scope. Check meaningful sequence, reachable controls and excessive duplicate stops.
Order need not be an exact geometric reading sequence. Record actual traversal; labels and
tree positions alone cannot prove it.
[Meaningful Sequence](https://www.w3.org/WAI/WCAG22/Understanding/meaningful-sequence.html),
[Focus Order](https://www.w3.org/WAI/WCAG22/Understanding/focus-order.html).

On modal entry, confirm useful focus and isolation from background content. On dismissal,
paging or selection, confirm meaningful recovery rather than demanding the same element always
regains focus. Do not repeatedly force focus on ordinary updates. Source routes include UIKit
accessibility containers/modal semantics and justified screen/layout-change notifications,
or SwiftUI `@AccessibilityFocusState`. Verify availability in the app's deployment target.
[Accessibility focus state](https://developer.apple.com/documentation/swiftui/accessibilityfocusstate).

Combine a related read-only row when it improves meaning. Use `.contain` where related children
need individual navigation; `.combine` can obscure independent child actions. `.ignore` requires
equivalent replacement semantics/actions. UIKit containers must expose the intended elements
and relationships. Test that a combined card retains separately actionable controls or an
equivalent discoverable action route; do not prescribe merging every container.
[SwiftUI grouping](https://developer.apple.com/documentation/swiftui/view/accessibilityelement(children:)),
[Info and Relationships](https://www.w3.org/WAI/WCAG22/Understanding/info-and-relationships.html).

## Provider limits and extra checks

Apple's native audit checks current presentation on supported OSes; collect category,
descriptions and optional element evidence, separating audit execution errors from findings.
The latest local amoo companion exposes `audit_accessibility_native`, backed by
`performAccessibilityAudit`. Inspect the installed schema; older companions may not expose it.
[Native audit](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/performaccessibilityaudit(for:_:)).

The local `test_voiceover` command uses iOS 27 `XCUIVoiceOverService` for bounded traversal and
returns original/restored enabled state. The underlying service provides forward/backward movement,
current speech and container movement. It does not expose a complete announcement stream,
focused-element identity, activation or rotor/custom-action control. Qualify additional routes
before claiming a full task completed using VoiceOver. Utterance wording varies by locale,
OS and settings; prefer semantic expectations over exact whole-sentence snapshots.
[VoiceOver service](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice).

For extended reviews, actual hit-region evidence is stronger than a frame under 44 points.
Screenshots can suggest contrast problems but cannot certify contrast without appropriate
measurement. Capture announcements during transitions; source notifications alone do not prove
speech or successful task completion. External companions cannot walk arbitrary UIKit objects
inside another app, and UIView traversal does not guarantee SwiftUI virtual-element coverage.

## Example evidence-backed tag

```yaml
ruleID: A11Y-GROUPING
ruleVersion: "1"
source: llmReview
status: needsReview
impactSeverity: high
effectiveSeverity: high
confidence: 0.7
stateID: detail.card
elementID: null
evidenceRefs: [source/Card.swift:42, artifacts/detail-tree.json]
observation: Card source combines a row containing two independent actions.
inference: One action may be unreachable during VoiceOver traversal.
mapping: "1.3.1 A candidate; confirm equivalent action access before marking a failure."
fix: Preserve child navigation or expose equivalent discoverable actions.
verificationNeeded: Traverse and activate both actions using qualified VoiceOver evidence.
```
