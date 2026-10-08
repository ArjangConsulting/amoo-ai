# Accessibility and VoiceOver

Research and implementation proposal, investigated October 7, 2026. This document does not
declare these proposed tools implemented or certify accessibility compliance.

## Implemented first slice

Local debug builds expose `audit_accessibility_native` (iOS native audit, explicit categories)
and `test_voiceover` (iOS 27+, 1–30 forward/backward focus moves, including up to six phases within one call). Traversal returns observed
utterances and original/restored enabled state, attempting restoration on success or API error.
It does not activate controls, manipulate the rotor, or capture asynchronous announcements.
A killed or wedged companion cannot guarantee cleanup: report unresolved restoration explicitly.
Runtime qualification belongs in task evidence, not inferred from compilation.

`find_elements` includes native picker values and optional selected state; absent selected state
remains unknown. Native wheels in sheets receive a bounded public-query supplement when the
root snapshot omits them. Raw hints and complete trait lists remain unavailable externally;
use speech/native trait audits or app-owned evidence. Android reports unsupported for these
iOS-specific inspections. Older companions may require rebuilding before the RPC is available.

Identifier-as-name and numerical 44-unit boundary heuristic bugs are fixed. Frame-size reports
retain every occurrence and explicitly describe unverified hit regions. The broader roadmap
below remains proposed: interactive VoiceOver state/move commands, policy-engine enforcement,
app-owned adapters, Android ATF and licensed providers are not implemented by this slice.

The review prioritizes text scaling, accessible names, useful hints, roles/states, reading
order/focus recovery and grouping. Rule selection, severity and provider categories must be
user-configurable. The [audit policy](accessibility-audit-policy.md) defines standards mappings,
impact ratings, configuration and evidence-backed LLM tagging. The distributable
[iOS skill](../plugins/amoo/skills/ios-accessibility/SKILL.md) and
[Android skill](../plugins/amoo/skills/android-accessibility/SKILL.md) support review and app fixes
now; runtime policy profiles and the broader adapters remain proposed. The first native
inspection slice above is implemented and qualified locally on iOS 27 SE and Pro Max simulators.

## Current capabilities and evidence limits

amoo can inspect labels, values, element types, enabled state, geometry, and identifiers, and
drive checked flows. Its current `audit_accessibility` is a limited hierarchy-based rule pack,
not a native accessibility audit or screen-reader test.

The host types in `Sources/AmooCore/Types.swift`, `Protos/common.proto`, and the iOS
`ElementSnapshot` carry optional selected state but not raw hints, complete accessibility traits,
focused state, custom accessibility actions, or accessibility language. An omitted field means
**unavailable**, not absent in the app. A passing label check does not establish spoken output.

Heuristic rule corrections and remaining limits:

- `MissingAccessibilityLabelRule` now flags unnamed controls even when they have automation
  identifiers. Regression coverage includes whitespace-only labels with a stable identifier.
- `SmallTapTargetRule` uses a fixed 44-unit frame threshold. Frames are not necessarily actual
  hit regions, nor are platform units interchangeable. Report the heuristic as such; use iOS
  points and Android density-independent units and platform-specific policies. Do not translate
  a platform touch-target recommendation directly into a WCAG failure.

Keep missing identifiers in testability, not accessibility compliance. Add an accessibility
domain rather than treating every UX/testability finding as an accessibility violation.

Visibility also needs care: the calendar investigation found `isVisible=true` for a partly
occluded day behind a pinned header. Retained lazy rows, existence, visibility, hittability,
and fully painted viewport coverage are different evidence. Reports should preserve this
distinction rather than silently selecting an offscreen node for an assertion.

## Supported platform routes

### iOS native audits

Apple's public `XCUIApplication.performAccessibilityAudit` is available from iOS 17
(macOS 14). The installed SDK exposes contrast, element detection, hit region, sufficient
description audits; Dynamic Type, clipped text, and trait audits are exposed for iOS-family
platforms. Action and parent-child categories are macOS-specific in the installed headers.
Check each category's SDK/platform availability rather than assuming parity.

The first slice wraps this inside the existing iOS companion and shared command contract, capturing issue type,
compact/detailed description, and the optional element as structured evidence. Prototype the
issue handler behavior so collecting findings does not accidentally fail or terminate the
long-running companion test. Native audit execution errors and unavailable categories are
coverage failures, not zero findings.

### iOS VoiceOver

The installed iOS 27 SDK declares public `XCUIDevice.voiceOverService` and
`XCUIVoiceOverService`: enable/disable, enabled state, forward/backward navigation, current
speech, and move-in/move-out. Navigation returns `XCUIVoiceOverOutput.utterance`.

The bounded amoo traversal wrapper uses these APIs without private calls and has been qualified
on iOS 27 SE/Pro Max simulators. Physical-device and older-OS qualification remains open, including
errors when no speech is available, focus movement, app activation, and teardown. Older OSes
must return an explicit unsupported capability; never silently substitute ordinary swipes.

The API exposes utterances, not a documented complete asynchronous announcement stream,
audio recording, raw hint property, or focused-element identity. A spoken result can verify
the user experience without proving which source property produced every word. Correlate
speech with tree evidence only when the association is established; do not manufacture an ID.
The inspected service header does not expose activation or rotor/custom-action control. A
navigation-and-speech wrapper is useful but cannot alone complete arbitrary VoiceOver tasks;
qualify any additional interaction route separately and expose its limits in capabilities.

`XCUIElementAttributes` publicly exposes `isSelected` and `hasFocus` on supported platforms,
but not a complete raw traits/hints interface. Export these with availability metadata;
`hasFocus` is not automatically proof of VoiceOver focus. No private KVC or undocumented
accessibility-server APIs.

### Optional app-owned instrumentation

An opt-in adapter in the target app can inspect its own UIKit accessibility labels, hints,
values, traits, custom actions, language, focused-element notifications, and announcement
completion notifications. The external companion cannot inspect arbitrary objects inside a
different process. SwiftUI virtual elements need a separate feasibility test; traversing
UIViews is not proof of complete SwiftUI coverage. Announcement callbacks alone do not prove
what a user heard. Keep this adapter optional, debug/test-only, versioned, and privacy bounded.

### Android

Investigate richer public accessibility-node semantics in the existing Android companion:
selected/checked state, role descriptions, actions, traversal relationships, and supported
language/focus information. Record what the actual backend can provide; do not promise raw
View or Compose properties from an external hierarchy.

Google's Accessibility Test Framework (ATF) is available through Espresso accessibility checks
and Compose test integration. Those integrations run inside app tests. However, ATF also has
builders accepting `AccessibilityNodeInfo` and `AccessibilityWindowInfo` inputs, so an
external-companion provider deserves a spike before requiring app instrumentation. Its
available checks and rendering evidence may differ from View/Compose integration. Pin a
released library version and qualify per-check coverage; source on `master` is feasibility
evidence, not a shipping compatibility guarantee.
[ATF hierarchy builders](https://github.com/google/Accessibility-Test-Framework-for-Android/blob/master/src/main/java/com/google/android/apps/common/testing/accessibility/framework/uielement/AccessibilityHierarchyAndroid.java).

TalkBack testing also requires qualifying coexistence with UiAutomation, which suppresses
accessibility services by default. Acquire it with `FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`
and configure UiAutomator consistently before its first connection. The current bridge uses
`instrumentation.uiAutomation` and does not explicitly configure this flag. Verify TalkBack
remains active during tree inspection and actions, not just before instrumentation starts.
[UiAutomation flags](https://developer.android.com/reference/android/app/UiAutomation#FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).

TalkBack enablement, focus navigation, speech observability, and restoration still need their
own public-API spike. Accessibility events or node text are not proof of TalkBack's actual
utterance. Keep an optional app-owned adapter for deeper metadata and View/Compose checks;
iOS VoiceOver support does not establish Android parity.

## Review findings in the current implementation

The implementation status and remaining source gaps are:

| Area | Current behavior | Required change |
| --- | --- | --- |
| Audit selection | `audit_accessibility` now selects the dedicated naming/bounds pack, excluding automation-ID rules. | General audits retain testability; native semantics and authored journeys remain separate evidence sources. |
| Names | The label heuristic no longer accepts IDs as spoken names; Android `UIAutomatorBridge.toRecord` collapses text and content description into one label. | Fix the ID false negative; preserve raw text, content description, naming relationships and provenance where available. Do not equate an empty raw property with an absent computed accessible name. |
| Geometry | Unknown/pixel units now prevent size findings and passing coverage; normalized points/dp use separate thresholds. | Capture density and coordinate space; convert Android pixels to dp for platform heuristics. Distinguish bounds from actual hit regions. |
| Evidence coverage | Rules require declared prerequisites; empty/partial captures cannot pass, while supported concerns are retained. | Make required evidence explicit per rule; empty, truncated, stale or unavailable trees cannot establish a clean screen. |
| Finding identity | Label/size rules aggregate a screen into one finding keyed by app ID and retain at most five elements. | Emit per-element occurrences with bounded, complete local artifacts; return only a compact preview to agents. |
| Confidence | `AuditEngine.run` preserves impact severity and confidence independently, including partial provider failures. | Preserve impact severity separately from confidence/review status; define which confirmed findings can fail CI. |
| Recording | `recordIfNeeded` now retains versioned structured audit/traversal evidence, with speech opt-in. | Persist versioned audit artifacts linked to action/state IDs; include coverage and execution errors. |
| Generated tests | `SessionPlanCompiler` explicitly classifies audits/traversal as diagnostic observations. | Keep exploratory scans diagnostic; add explicit audit checkpoints/assertions for replay and supported emitters. |
| Assistant claims | Assistant reports describe naming heuristics only and retain structured observations with verdict `notAssessed`. | Describe the actual inspected evidence and omitted checks; no implied screen-reader or native-audit pass. |

Use the existing per-device `DeviceOperationQueue` for audit and screen-reader work. An actor
alone does not prevent races across suspension points. Background audit hooks must remain
inside the same ordering boundary, including `run_steps`, flow replay and session teardown.

## Auditing while moving between screens

The primary product should be a **journey audit** attached to a leased test session. Users
follow their normal checked flow and receive one report covering visited states and transitions.
An automatic crawler can follow later; authored navigation already gives useful, bounded
coverage without guessing which controls are safe to activate.

Proposed modes, initially exposed through explicit checkpoints:

- **Checkpoint:** audit a named state after a readiness assertion; easiest to reproduce in CI.
- **Observe as you drive:** opt in to automatic checkpoints after successful state-changing
  steps, such as opening a screen, scrolling to new content, showing a sheet, changing a
  selection or displaying validation errors. Query tools and audit calls never trigger scans.
- **Assistive-technology journey:** run a separate flow using qualified screen-reader
  navigation/activation and semantic speech assertions. Ordinary taps with VoiceOver enabled
  do not establish that the task can be completed by a VoiceOver user.

“Screen” means a captured UI state, not just a route name. The same route can have a keyboard,
dialog, expanded control, loading/error state, or different scroll position. Preserve explicit
state names and visit IDs; fingerprints are deduplication aids, not evidence that two states
are semantically identical. Avoid including volatile copy or private values in identity keys.

```mermaid
flowchart LR
    A[Checked action] --> B[Readiness and bounded stabilization]
    B --> C[Capture state and transition evidence]
    C --> D[Run supported providers]
    D --> E[Persist findings and coverage]
    E --> F[Continue journey or apply failure policy]
```

Capture the initial state too. After each eligible action, use a caller-supplied readiness
condition where possible and bounded stabilization otherwise. A timeout, continuous animation,
app switch or changed state during capture must produce incomplete/unstable coverage. Record
capture timestamps and before/after state checks: a tree, screenshot and provider result are
not automatically an atomic observation. Native audits may exercise presentation settings;
qualify their side effects and re-check app state before continuing.

Audit hooks observe the same active app, reuse suitable fresh observations, and never drive
extra navigation themselves. Budget provider time, state count, tree size and artifact size.
On budget exhaustion, persist the unexamined states/categories. Let users request a checkpoint
even for a previously seen state, especially after a settings change.

Transition checks need evidence before and after the action: focus moves into a modal,
background content is excluded while it is open, dismissal restores meaningful focus, errors
are discoverable, and selection/loading changes communicate their result. Collect transient
events during the action when the backend supports them; a post-action static audit cannot
recover missed announcements. Without qualified focus/speech evidence, mark those checks
`needsReview` or `unsupported` rather than inferring behavior from labels.

### Reporting and failure policy

Persist a versioned journey report with separate collections for states, transitions, check
evaluations, findings and artifacts. Each evaluation identifies its provider/version,
requested category, actual support, status and reason. Each finding has a stable defect key
plus occurrence IDs linked to visits/transitions and element evidence. Prefer a real stable
selector plus structural context; explicitly mark fallback matching as uncertain. Do not merge
every unnamed control in an app or discard repeats that demonstrate a regression.

Produce local JSON and a navigable HTML report with annotated evidence, affected states,
reproduction steps, remediation and unresolved manual checks. A later SARIF exporter can
support code-review integrations when reliable source locations exist; do not invent them.
Carry artifact references through session persistence and redaction/retention policies.

Default to collecting findings so a journey reaches later screens. Configure separately:
finding thresholds, mandatory-provider/coverage requirements, and whether to stop immediately
or fail at journey end. “No findings in evaluated checks” and “all requested checks completed”
are separate results. A disconnected provider cannot pass CI because its finding list is empty.
Baseline matching must retain provider/check versions and report uncertain matches for review.

### Replay and generated tests

Store automatic scans as diagnostic artifacts, without expanding every tap into generated
source. Store explicit audit assertions as first-class plan operations, carrying categories,
provider requirements and failure policy. XCUITest can emit native audits on supported OSes;
Espresso/Compose checks require an app-owned test dependency/configuration. Companion-only
checks can replay through amoo flows; unsupported standalone exports must surface an incomplete
plan or required helper binding. Never silently omit a requested accessibility assertion.

An acceptance journey should cover list → detail → modal → dismissal → validation error,
including a scroll checkpoint. Seed defects in separate states; confirm all are retained,
repeated findings deduplicate without losing occurrences, and failed/unavailable providers
remain visible. Restart from persisted artifacts and verify the same coverage summary.

## Breadth of accessibility support

“Full support” should mean an explicit capability and evidence matrix, with automated and
human-review routes. It cannot mean proving every accessibility requirement from a UI tree.

| Capability family | Automated route to qualify | Coverage that still needs review |
| --- | --- | --- |
| Names, roles, states, values and actions | Native audits, richer nodes, optional app metadata | Whether descriptions and custom actions make sense in context |
| Reading order, grouping and focus recovery | Screen-reader journey assertions and transition evidence | Rotor use, pronunciation, complex widgets and task usability |
| Visual presentation | Native/ATF audits; settings-specific journeys for text size, theme and contrast | Image-only content, meaningful non-color cues and false-positive review |
| Motor and alternate input | Capability probes and authored keyboard/alternate-input flows | Switch Control/Switch Access, Voice Control/Voice Access and gesture alternatives until qualified |
| Motion, timing and interruption | Authored Reduce Motion, timeout and interruption scenarios | Vestibular comfort, adequate response time and cognitive load |
| Localization and bidirectional layout | Explicit locale runs and translated speech expectations | Translation quality and meaningful language switching |
| WebView content | Separate DOM audit provider where debugging/DOM access is supported | Native/web focus transitions and browser/screen-reader behavior |
| Media | App-owned metadata and explicit playback scenarios | Caption accuracy, audio description and equivalent alternatives |

Keep native and web evidence separate while linking them to the same journey state. An
inaccessible DOM debugging connection is missing coverage, not an accessible WebView. Settings
mutation needs its own supported/unsupported matrix per device backend; requesting a setting
does not prove it changed. Re-run the same flow for each chosen configuration and attach the
observed settings to the report. Prefer authored representative journeys over an unbounded
Cartesian product of every setting.

## Proposed contract and safety requirements

Names below are proposals, not existing commands:

- `accessibility_capabilities`: OS/SDK/backend versions and per-feature support/reason.
- `audit_accessibility`: explicit native/heuristic provider and selected categories, bounded
  execution, and a structured report; retain compatibility with the existing command.
- `voiceover_state`, `voiceover_set_enabled`, `voiceover_move`, `voiceover_current_speech`:
  lease/session scoped, serialized through the device executor, bounded responses.
- Checked flow assertions for accessible name, selected/enabled state, spoken semantic content,
  focus sequence, picker dismissal, and focus recovery. Avoid exact whole-utterance snapshots
  across different OSes/languages unless intentionally version-pinned.

Add protobuf fields without reusing tags. Optional values and evidence provenance distinguish
unknown/unsupported from false/empty. Negotiate old companion compatibility. Include source
(native audit, hierarchy, speech, app instrumentation, image heuristic, or human review),
confidence, coverage, platform units, app/build, locale, OS, and capture state.

Restore the original assistive-technology state after success, timeout, cancellation, transport
failure, and lease release. Preserve pre-existing VoiceOver rather than always disabling it.
Use bounded cleanup and report cleanup failure prominently. Serialize operations so audit,
navigation, and app-switch commands cannot race. Set step/time/output budgets; no unbounded
screen crawl or activation of purchases, deletions, or external messaging. Screenshots, text,
and spoken output may contain private data: redact logs and make exports explicit.

Process death and device disconnection can prevent immediate restoration. Persist original
state and pending cleanup before mutation, attempt recovery when the owning lease reconnects,
and block further settings mutation if restoration is unresolved. Do not overwrite changes
made by a human or another owner. Apply this lifecycle to text size, appearance and other
accessibility settings as well as screen-reader enablement.

Reports need per-issue stable identity, element evidence, annotated screenshot where useful,
remediation, provider/version, and relevant guideline mapping only when justified. Keep
`pass`, `fail`, `needsReview`, `unsupported`, and `executionError` separate. Baselines require
reviewer/rationale/expiry; suppressions must not convert untested areas into passes. Deduplicate
across states while retaining affected states. Store large artifacts locally and return compact
summaries/paths to agents.

## Detection principles

Provider examples are references, not the product specification. Select checks by actionable
concerns, evidence requirements and demonstrated usefulness on seeded defects. Compare false
positives, missed concerns, incomplete coverage and remediation quality rather than finding counts.
Do not infer WCAG conformance or screen-reader task usability from a provider's clean scan.

Preserve confidence separately from impact. Missing capture fields and unstable presentation
must prevent a clean verdict while retaining concerns supported by the available evidence.
Native provider findings remain scoped provider observations; semantic acceptance requires
explicit app/task assertions and review. Keep providers replaceable and local evidence first.

## Delivery sequence and acceptance gates

1. **Evidence correctness:** fix identifier-as-label false negatives; separate accessibility
   from testability; add optional selected/focus fields and capability/provenance reporting.
   Unit tests cover empty labels with IDs, unknown metadata, platform units, old companions,
   and partially occluded nodes. No unsupported result may become a pass.
   Add the versioned rule catalog/policy resolver, separate standards level from impact,
   confidence and disposition, and preserve configured exclusions in evidence coverage. Use
   the policy acceptance gates; skills can guide reviews before engine enforcement ships.
2. **Public-API spikes:** qualify native audits independently on iOS 17+; qualify VoiceOver
   navigation/speech on iOS 27 and rejection on older OSes. Test native issue collection without
   recording failures against the companion's long-running XCTest. Spike Android ATF node/window
   input and TalkBack coexistence in parallel feature tracks. Record seeded findings, coverage,
   speech where observable, and cleanup/recovery paths. Do not expose production commands before
   their respective gates pass; native auditing must not depend on VoiceOver availability.
   Prioritize the six core rule families. Qualify raw hint/trait availability separately from
   computed semantics and speech; route unsupported contextual checks to skill/LLM review with
   evidence, not an automatic violation or pass.
3. **Contract and flows:** wire shared protocol, iOS driver, CLI, MCP, recording/assertion
   support, documentation, and amoo subagent skill guidance. Follow the command-contract and
   codegen-pipeline guides. Build the companion separately; run unit/protocol integration
   tests, lint, and amoo-only device qualification. Add Android routes without implying parity.
4. **Journey MVP:** explicit named checkpoints, persisted JSON/HTML reports, state/transition
   links, per-element findings and independent finding/coverage failure policies. Ship this
   before optional app adapters or commercial providers. Qualify the seeded multi-state
   acceptance journey above, including cancellation, provider timeout and session restart.
5. **Depth:** automatic observe-as-you-drive checkpoints, qualified assistive-technology flows,
   app-owned metadata adapters, Android View/Compose integration, optional provider adapters, baselines,
   WebView providers and explicit manual-review workflows. Test seeded missing
   names, conflicting traits, clipped text, contrast, small hit regions, reading-order errors,
   lost focus after dismissal, and missing announcements. Track misses and false positives.

Qualification matrix: small/large phones, simulator/real device, minimum/current supported OS,
default/largest text, light/dark/increased contrast, Reduce Motion, Differentiate Without Color,
LTR/RTL, at least English plus a genuinely translated RTL language, native/WebView where
supported. Automation does not replace hands-on VoiceOver/TalkBack task completion, rotor,
custom-action discoverability, pronunciation, and usability review.

## Calendar case study: confirmed versus still open

The SwiftUICalendar branch using SwiftUIComponents 0.18.1 was inspected with amoo on an iOS 27
SE simulator. Picker targets, enabled-state observation, selected-date label, bidirectional
vertical scrolling in MVVM/TCA, and maximum-text edge-date reachability passed. This did not
verify real VoiceOver speech, hint values, selected traits, or disabled-date interaction.

Subsequent local `amoo-debug` subagent runs on SE and Pro Max verified native audits,
selected-state export, year-wheel values, bounded VoiceOver traversal, restoration of the
original VoiceOver state, and concurrent cold companion startup. The calendar now gives the
month control a contextual name and both month/year controls gesture-independent change
hints. Actual SE speech confirms those hints. Built-in day renderers retain the selected trait
without repeating selection in their label; actual speech confirms a single selection
announcement. The public day-context label remains unchanged for custom renderers.
These are English-baseline simulator results, not full accessibility conformance.

A subsequent broader calendar fix adds weekday context, range start/end/interior descriptions,
named full secondary-calendar dates, month/year-page heading traits, selected decade-grid years,
and contextual year-page navigation names. SE speech verified weekday and range roles without
duplicating selected state. Pro Max verified Persian date/calendar context. Heading semantics
and the custom decade grid remain runtime-unverified. Separate backward traversal calls restart
at the initial boundary when each call restores disabled VoiceOver; they do not establish reverse
order or continuous focus recovery. The bounded multi-phase command now preserves the service
within one call and restores it at the end; calendar-specific reverse order and focus recovery
still need authored assertions and runtime qualification.

Source review identified these follow-ups, not all device-confirmed failures:

- The calendar string catalog has English translations only. Calendar/date locale
  formatting is not translated UI copy. Define supported UI languages, translate the catalog
  (including shared picker strings), and test UI-language versus calendar-locale policy.
- Verify month/year-page heading semantics and custom decade-grid selection/navigation at
  runtime; the phone sample uses a native wheel rather than the custom decade grid.
- Review the sample's Persian-primary/Persian-secondary fixture, which repeats the same
  calendar/date; this is not evidence of missing calendar identity.
- Verify focus order/recovery during paging, external navigation, picker dismissal and range
  selection; announcements in translated languages; disabled/boundary actions; custom day
  renderers; and Reduce Motion/contrast/non-color state differentiation.

Use these as checked calendar regression flows once the new capabilities are qualified.
Structural snapshots and current label unit tests cannot establish assistive-technology
behavior. Keep consumer fixes and their migration notes in the calendar/dependency PRs.

## Next reporting and agent-integration priorities

These priorities are implemented in the current source/build slice; the new reporting and
multi-phase traversal still need runtime qualification. The broader roadmap above remains proposed:

- Session actions retain versioned `diagnosticEvidence` with audit issues, coverage, speech phase
  boundaries and cleanup. `record_speech=true` explicitly opts into persisted speech; by default
  speech slots remain redacted placeholders. Known session secrets are redacted, including secrets
  registered after the observation. Evidence stays linked to its recorded action/timestamp.
- Audit/traversal observations are diagnostic and compile as `notApplicable`, including legacy
  recordings. They never become accessibility assertions or excluded generated-test steps.
- Inspection output separates `executionStatus`, `verdict`, coverage, truncation and `cleanupStatus`.
  VoiceOver speech capture remains `notAssessed`; native verdicts require completed category coverage.
  Cleanup errors preserve the traversal's execution status and partial evidence independently.
- `amoo agent install --binary /absolute/path/to/amoo` pins the executable in generated standalone
  MCP configs (default: the running executable's resolved absolute path). Shell aliases do not apply.
  MCP responses expose host build metadata for legacy and modern protocols. Inspection provenance
  includes advertised companion capabilities and the actual companion executable SHA-256.
  Session-installed app artifacts are fingerprinted before/after installation; configured launch locale
  is separate from an externally unavailable observed app UI locale. Shared plugin manifests stay portable; use a
  locally installed agent/configuration to pin a debug binary.
- The amoo subagent emits a compact version 2 JSON contract (replacing its previous YAML report).
  `amoo agent validate-report --report <path> --run-id <UUID> --checks <caller-check-ids>` validates
  caller identity, coverage, assertion outcomes, sealed evidence files and cleanup. The CLI requires
  the parent's original run ID and checks; validation does not independently certify evidence semantics.
- `test_voiceover phases='[{"steps":5,"direction":"forward"},{"steps":5,"direction":"backward"}]'`
  keeps one VoiceOver service enabled across phases and restores it once at the end. Bounds are
  six phases and 30 total moves. Capability negotiation rejects older companions before traversal,
  with explicit rebuild/OS remediation. `start_session.owner` explicitly identifies the owning MCP process; delegate
  app/build/device requirements, never a live session ID.

The original recommendations motivating this slice were:

1. Persist typed, versioned accessibility observations or immutable local artifact references.
   Session recording previously retained textual summaries but dropped structured issue/speech and
   restoration evidence. Apply explicit data-retention/redaction rules; do not persist arbitrary
   speech unconditionally.
2. Classify native audit and VoiceOver traversal as diagnostic observations in recording and
   compilation. They previously fell outside the compiler's query-only vocabulary and could produce
   excluded-step warnings. Observation is not a replayable accessibility assertion.
3. Separate execution status, verdict, and coverage. Successful speech capture is `notAssessed`
   until explicit semantic assertions are evaluated. Report requested/evaluated checks,
   not-evaluated reasons, truncation, app/build/device/locale provenance and cleanup separately.
4. Pin the executable used by generated MCP/subagent configuration to an absolute path; shell
   aliases do not select a spawned MCP binary. Expose companion capabilities and fingerprints,
   and return unsupported-capability remediation rather than blindly restarting old companions.
5. Validate a compact versioned subagent report with run ID, assertion outcomes, coverage,
   evidence references and cleanup. Keep raw evidence out of the parent transcript. A reported
   pass requires all requested checks evaluated and passed, not merely tool execution success.
6. Preserve traversal within a bounded multi-phase speech command when testing forward/backward
   order. Separate calls that restore disabled VoiceOver cannot establish continuous focus
   recovery. Do not bypass process-owned MCP sessions; delegate requirements or introduce an
   explicit lease-transfer protocol if exact-state handoff is needed.

## Primary references

- [Apple VoiceOver service](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice)
- [Apple native accessibility audit](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/performaccessibilityaudit(for:_:))
- [Apple focused element](https://developer.apple.com/documentation/uikit/uiaccessibility/focusedelement(using:))
- [Google Espresso accessibility checks](https://developer.android.com/training/testing/espresso/accessibility-checking)
- [Google Compose accessibility testing](https://developer.android.com/develop/ui/compose/accessibility/testing)
- [Google ATF hierarchy builders](https://github.com/google/Accessibility-Test-Framework-for-Android/blob/master/src/main/java/com/google/android/apps/common/testing/accessibility/framework/uielement/AccessibilityHierarchyAndroid.java)
- [Android UiAutomation service coexistence](https://developer.android.com/reference/android/app/UiAutomation#FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
- [Evinced XCUI SDK](https://developer.evinced.com/sdks-for-mobile-apps/xcui-sdk/)
- [Evinced mobile reports](https://developer.evinced.com/sdks-for-mobile-apps/mobile-reports/)
- [Evinced XCUI release notes](https://developer.evinced.com/sdks-for-mobile-apps/release-notes/xcui-sdk/)

## Evidence and acceptance safeguards

- Built-in heuristics declare prerequisites. Empty/placeholder captures, missing geometry and
  unnormalized pixels cannot establish complete coverage. Size thresholds apply to explicitly
  normalized points (44) or dp (48), describe bounds only, and do not certify effective hit regions.
- Rule failures preserve findings and coverage from other rules. Severity is never downgraded
  merely because confidence is low. Incomplete evidence can still produce actionable concerns.
- Assistant naming/testability diagnostics are retained as observations and make no clean-audit claim.
  Screenshot annotations are withheld when before/after screen tokens differ.
- Compact report v2 artifacts carry path, SHA-256, run ID and associated checks. Acceptance requires
  the caller's original run/check IDs, regular bounded files, matching hashes and scoped references.
  Hashes do not certify assertion semantics. Unknown required provenance cannot support a pass.
- Host source commit, source fingerprint and dirty state are stamped at build time. Host executable
  SHA-256 identifies the actual binary; atomic replacement is detected even with preserved mtime.
- VoiceOver persists original enabled state and move counts before mutation, without speech. The
  journal lives in a shared app-group container anchored by the installed companion host, because
  Xcode can delete and recreate the runner's private container after a crash. Startup and the next
  traversal recover pending restoration; startup recovery state is exposed in inspection provenance.
  Cleanup errors retain the marker and block new traversal. Unavailable recovery storage is a refused
  capability, never a fallback to volatile storage. Keep the host installed until cleanup completes.
- The owning simulator holder watches both its Xcode process and bounded capability RPCs. Three
  consecutive failed probes trigger a restart within the same lease, up to three restarts. Successful
  probes reset the count. Notifications carry runner generations so a duplicate crash event cannot
  restart the replacement. Attached companions and physical-device tunnels are excluded from this
  automatic restart path; their owner must reconnect explicitly.
- Cancellation, deadline and target identity are checked before/after moves. Enablement and final
  restoration are verified by reading state. A blocked synchronous XCTest call cannot be forcibly
  interrupted. A transport error remains execution failed, verdict not assessed and cleanup unknown;
  later recovery evidence does not retroactively establish traversal coverage or an accessibility pass.

`audit_accessibility` no longer reports missing automation identifiers or hierarchy-depth concerns.
Use `audit_app` with the testability pack for those automation checks.

## Crash and transport recovery qualification

Use a dedicated simulator lease and the companion fixture, preserving the originally enabled state.
Install the host and runner built together. `make companion-ios-build`, source builds through amoo,
and release simulator packaging apply the same ad-hoc signing step to the generated executable runner
and host. Declaring an entitlement on only the test bundle does not authorize the generated runner.
Physical builds require the common registered group described in [physical iOS setup](physical-ios-devices.md).
The shared container's lifetime depends on retaining at least one group member. See Apple's
[app-group storage lifecycle](https://support.apple.com/guide/security/sec1a976c067/web).

For crash injection, observe a fresh journal with at least one completed move, then SIGKILL only the
runner whose PID, port and simulator container match the owned holder. Verify that the holder and
lease remain the same, the shared container survives runner recreation, startup provenance reports
restoration, and public Settings independently matches the original state before another traversal.
Marker disappearance alone is not proof of recovery. Repeat with VoiceOver originally off and on.

The checked-in `VoiceOverRecoveryQualificationTests` exercise the actual gRPC deadline and client
task cancellation. They are opt-in and do not lease, launch, restart or release someone else's device.
The verifier supplies `AMOO_LEASE`, sets `AMOO_VOICEOVER_FAULT_QUALIFICATION=1`, and supplies:

- `AMOO_VOICEOVER_FAULT_PORT`: port of its owned companion.
- `AMOO_VOICEOVER_FAULT_APP`: foreground fixture bundle ID.
- `AMOO_VOICEOVER_FAULT_JOURNAL`: absolute path to that simulator's shared journal.
- `AMOO_VOICEOVER_FAULT_EVIDENCE`: absolute private output directory for this case.

Run each test separately, checking cleanup between cases:

```sh
swift test --filter 'VoiceOverRecoveryQualificationTests/testClientDeadlineLeavesCleanupUnknown'
swift test --filter 'VoiceOverRecoveryQualificationTests/testClientCancellationLeavesCleanupUnknown'
```

Both require a fresh progress checkpoint; the deadline test uses a real five-second transport deadline.
Their JSON artifacts intentionally report cleanup unknown. After each test, independently observe
journal clearance and verify public Settings before another traversal, which could itself recover
pending cleanup and hide a cancellation failure. If the API stops responding, observe the owning
holder's bounded restart and verified startup recovery. Restore the original setting and release the
lease after all cases. Device disconnects, physical devices, older OS versions, and indefinitely
blocked platform calls need separate qualification.

On the iOS 27.0 iPhone 17 simulator, the crash/deadline/cancellation matrix passed with VoiceOver
originally off and on. Crashes recreated the runner's data container but preserved the shared journal;
the same holder/lease restarted automatically and exposed verified startup restoration. All four
transport faults retained failed execution, no accessibility verdict and unknown caller cleanup.
Independent Settings checks confirmed restoration before another traversal, with no false health
restart. The original off state was restored and the owned lease/holder released. The automatic
build signing path also passed build and signature/entitlement verification.

Authored accessibility journey assertions are now available through
`assert_accessibility_journey`; see [the contract and fixture](accessibility-journeys.md).
The implementation checks accessible name,
role and state, bounded focus order, and focus recovery after paging, navigation or dismissal.
Associate failures with a specific element and transition, preserve raw evidence and distinguish
unsupported or untested semantics from failed expectations. Keep qualification scoped to seeded concerns
and clean controls before adding automatic violation rules. This provides actionable findings
beyond observational speech without importing a commercial scanner's assumptions.
