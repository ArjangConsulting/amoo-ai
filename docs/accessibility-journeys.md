# Authored accessibility journeys

`assert_accessibility_journey` runs app-authored checkpoints on iOS 27+ through a companion
advertising `accessibility.authoredJourney.v1` and durable VoiceOver recovery. All steps share
one enabled service; the original enabled state is verified and restored once at the end.
Android and older companions return unsupported, with no passing coverage.

Pass requires successful execution, every requested expectation evaluated and passing, and
untruncated evidence. The MCP call also fails when cleanup is unresolved. Reports keep
execution, assertion verdict, coverage and cleanup separate. A confirmed expectation failure
remains a failure even if later checkpoints are not evaluated. These are authored task checks,
not automatically inferred violations or whole-app conformance.

Supply `app_id` and `journey` (a JSON string, at most 128 KiB). Version 1 has `schemaVersion`,
`id` and `steps`. IDs must be nonblank, at most 256 characters; step IDs must be unique. There
are 1–20 steps and at most 30 worst-case moves, including seek bounds. Assertions are exact
and locale-specific; no role or selected state is parsed out of speech.

## Checkpoint kinds

- `element`: `element` has exact `id` and one or more expected `name`, `role`, `value`,
  `enabled`, `selected`. Each property has separate coverage. `name` is the exported XCTest
  label, `role` a supported XCTest type (`button`, `link`, `checkBox`, `radioButton`,
  `staticText`, `image`, `textField`, `secureTextField`, `switch`, `slider`, `picker`,
  `pickerWheel`, `cell`, `alert`, `sheet`), and
  state is public snapshot metadata. This does not certify the complete raw trait set,
  heading semantics, meaningful label wording, hit regions or accessibility actions.
  Unsupported element types expose unavailable role rather than an automation-type grouping.
  Missing properties are unsupported; duplicate IDs need review. Empty observed names can
  fail an explicitly authored nonempty name expectation. IDs locate targets; they are not names.
- `seek`: `direction` is `forward` or `backward`, `maxMoves` is 1–30, and `speech` contains
  one expectation. This establishes a bounded anchor before an order check or transition.
  Failure stops later steps instead of moving them from an unestablished focus position.
- `order`: `direction` and a nonempty `speech` array specify the expected speech from each
  successive move, without ignoring intermediate stops. Reverse order uses a subsequent
  backward step in the same call. A failed sequence stops subsequent checkpoints.
- `transition`: `element` specifies the unique action target and its expected metadata;
  `action` is `tap` or `doubleTap`; `before` and `after` are required speech expectations;
  `destination` specifies metadata that must newly match after the action. Before speech
  is read without moving. The action is withheld if its anchor or target is wrong. The
  destination must differ from its previous capture and must not have already matched.
  Then current speech is read without a repair move or VoiceOver disable/enable. Optional
  `recoveryTimeoutMS` bounds this wait from 0 to 5000 milliseconds (default 2000), with at
  most 21 samples. Intermediate speech remains evidence; only matching speech within the
  bound establishes recovery. Zero requests one immediate read. A synchronous read that
  completes after a positive deadline leaves recovery not evaluated. Failed
  readiness never establishes focus recovery. Use a destination name/value/state that
  changes on paging, navigation or dismissal; an unchanged background control is insufficient.

Each speech expectation has exactly one nonblank `equals` or `contains` string, at most 4096
characters, and an optional `elementID` association supplied by the author. Choose narrow,
contextual terms; a broad substring can match the wrong stop. The public
[VoiceOver service](https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice)
exports utterances but no focused element identity. Associations in a report do not manufacture
that identity. Targeted XCTest gestures do not certify screen-reader activation, rotor or
custom-action usability. No focus KVC or private accessibility server APIs are used.

## Example: paging

This fixture example establishes the action anchor, performs a transition with VoiceOver still
enabled, verifies changed page metadata, and checks current speech for recovery:

```json
{
  "schemaVersion": 1,
  "id": "paging",
  "steps": [
    {
      "id": "option-semantics",
      "kind": "element",
      "element": {"id": "a11y-option", "name": "Selected option", "role": "button", "selected": true}
    },
    {
      "id": "next-anchor",
      "kind": "seek",
      "direction": "forward",
      "maxMoves": 15,
      "speech": [{"elementID": "a11y-next", "contains": "Next page"}]
    },
    {
      "id": "next-page",
      "kind": "transition",
      "element": {"id": "a11y-next", "name": "Next page", "role": "button", "enabled": true},
      "action": "doubleTap",
      "before": {"contains": "Next page"},
      "destination": {"id": "a11y-page", "name": "Page 2"},
      "after": {"elementID": "a11y-page", "contains": "Page 2"}
    }
  ]
}
```

The companion host fixture opens at `amoo://accessibility?seed=clean`. Wait for `a11y-seed`
to export `Fixture seed: clean` (or the requested seed) before checking it. Seeds `name`, `role`,
`state`, `order`, `focus` and `dismissal` introduce one concern each. Reopen/relaunch the fixture
between cases to reset its page/dialog state. Compare identical authored expectations against
each concern and the clean control. For order, seek `First journey item`, then expect
`Second journey item` on the next forward move. Test the backward phase within that call too.
For dismissal, seek/open the dialog, check its title for context, seek the dismiss anchor,
then verify the changed `a11y-dialog-state` checkpoint and current speech returning to `Open dialog`.
The [dialog example](examples/accessibility-journey-dialog.json) keeps these phases in one call.
The clean paging fixture posts a public UIKit `layoutChanged` notification with its updated
page label as the focus target, deferred 300 ms after activation; the focus seed omits this request.
An immediate request did not establish recovery in qualification. It does not announce the
expected string to manufacture a match.

## Qualification limits

Inspect failed anchor evidence before attributing a concern to the target app. During iOS 27
qualification, traversal retained Settings speech after launching the fixture with VoiceOver
already enabled through Settings. The fixture was frontmost, but its anchor was not established,
so the action was withheld. That result does not establish a paging or focus-recovery defect.
Keep cross-app setup and provider behavior distinct from an authored task mismatch.

The public service exposes speech rather than a focused element ID. A passing speech expectation
is scoped to that authored utterance and transition; it does not independently establish focus
identity or validate every screen-reader interaction.

## Evidence and persistence

`journey.checks` records check ID, checkpoint ID, expected target, transition ID, evidence source,
expected/actual comparison and `pass`, `fail`, `unsupported`, `needsReview` or `notEvaluated`.
`journey.specification` binds the report to the full authored input, including expectations
and bounds. `journey.checkpoints` retains bounded raw element/speech captures in operation order.
Speech evidence is capped at 128 utterances of 4096 characters; exceeding a bound marks
the result truncated and prevents a pass.
Transition captures name `targetBefore`, `destinationBefore` and `destinationAfter`, including
empty captures, so absent evidence cannot lose its boundary. Transport
failure has no evaluated coverage and unknown cleanup. A missing or mismatched version, journey
ID, specification or check set in the companion response cannot become a pass. Cleanup
restores the original VoiceOver enabled state; it does not restore focus.

Session reports retain the authored assertion and its structured results. Raw utterances and
actual speech comparisons are omitted unless `record_speech=true`; known session secrets are
redacted, including secrets registered later. Expected authored terms remain in the request and
report. Keep these artifacts local. Native auditing and observational `test_voiceover` remain
diagnostic; an authored journey is an assertion.

The session compiler emits an `excluded` warning for journey assertions, including failed ones.
Current XCUITest/Espresso generation cannot reproduce their native runner lifetime, so normal
complete export blocks. `--allow-incomplete` retains the existing explicit failing-gap behavior;
it does not certify that the journey is reproduced.

## Live fixture qualification

On the iOS 27 simulator, the clean metadata, bidirectional order, paging and dialog journeys
pass their complete authored checks. Identical inputs against each seed isolate these failures:

| Seed | Failed expectation |
| --- | --- |
| `name` | Option name |
| `role` | Option role |
| `state` | Option selected state |
| `order` | Next forward stop; subsequent reverse checkpoint remains not evaluated |
| `focus` | Recovery to the updated page |
| `dismissal` | Recovery to the dialog's opening control |

All runs retain execution success separately from these expected assertion failures, with
untruncated evidence and verified restoration of the original OFF state, independently confirmed
in public Settings after the run. The owning session and processes are released. The clean order checks
forward and backward traversal in one call. The dialog checks opening context, seeking Dismiss,
dismissal readiness and return focus in one call. Paging and dialog use the default two-second
recovery bound. These results qualify the fixture and provider path, not arbitrary apps or
whole-app accessibility conformance.
