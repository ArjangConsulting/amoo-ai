# Accessibility checks

`check_accessibility` runs the accessibility checks a project opted in to on the current screen. The
project picks them once, in `amoo init` or in `amoo.config.json`. An agent or flow then calls the tool on
each screen it verifies, and it always runs the same list. Nothing is checked unless the project opted in.

## Opting in

`amoo init` asks two questions after the screenshot settings. Both start with nothing selected:

1. **Checks to run on each screen.**
2. **Configurations to repeat them in.** This question is only asked when at least one check is selected.

Headless runs answer with flags. Each flag takes a comma list, `all` or `none`:

```bash
amoo init --platform ios --device <udid> \
  --accessibility-checks names,contrast,target_size \
  --accessibility-configurations dark_mode,large_text
```

The answers are saved in [`amoo.config.json`](amoo-config.schema.json). You can also edit that file
directly, and `amoo config validate` checks it:

```json
{
  "version": 1,
  "accessibility": {
    "checks": { "names": true, "contrast": true, "target_size": true },
    "configurations": { "dark_mode": true, "large_text": true }
  }
}
```

A name that is left out counts as `false`. An unknown name makes the config invalid rather than being
ignored, so a typo cannot turn a check off. Nested configs merge by name, which lets a platform
repository turn off one check without repeating the orchestrator's list.

### Checks

| Check | What it evaluates | iOS native audit | Android ATF |
| --- | --- | --- | --- |
| `names` | Controls and images have a spoken name | `sufficientElementDescription` | `SpeakableTextPresentCheck`, `EditableContentDescCheck`, `DuplicateSpeakableTextCheck` |
| `target_size` | Touch targets are large enough | `hitRegion` | `TouchTargetSizeCheck` |
| `contrast` | Text contrasts with its background | `contrast` | `TextContrastCheck` |
| `text_clipping` | Text is not clipped or truncated | `textClipped` | unsupported |
| `text_scaling` | Text follows the system text size | `dynamicType` | unsupported |
| `traits` | Roles and traits match the control | `trait` | unsupported |
| `element_detection` | Interactive content is exposed to assistive technology | `elementDetection` | unsupported |

An opted-in check that the platform has no audit for is listed under `unsupportedChecks` with the
reason. It is never reported as passed.

### Configurations

| Configuration | Setting changed | iOS simulator | Android |
| --- | --- | --- | --- |
| `dark_mode` | Appearance → dark | `simctl ui appearance` | `cmd uimode night` |
| `large_text` | Text size → largest | `simctl ui content_size accessibility-extra-extra-extra-large` | `settings put system font_scale 2.0` |
| `increase_contrast` | Increased contrast on | `simctl ui increase_contrast` | `settings secure high_text_contrast_enabled` |

## What a call does

1. It reads the original value of every setting the opted-in configurations change. If a setting
   cannot be read, that configuration is not evaluated and nothing is changed, because the original
   could not be put back. Physical iOS devices fall in this case, since `devicectl` cannot read these
   settings.
2. It runs the **default** pass with every touched setting at its default (light, standard text,
   contrast off), so the baseline does not depend on how the device was left.
3. It runs one more pass per opted-in configuration, with only that setting changed. After each
   change it waits `settle_ms` (default 1500), confirms the app is still in the foreground, and reads
   the setting back. A value the device did not take means that pass is not evaluated.
4. It restores every original value and reports `cleanupStatus`.

The result is `verdict=pass` only when every check this platform can run was evaluated and passed in
every pass. Otherwise the result is `fail` or `notAssessed`, and the call is an error, so a flow step
fails on it:

```json
{ "tool": "check_accessibility", "arguments": { "app_id": "com.example.app" } }
```

Android recreates the activity when font scale changes. The tool checks that the app is still in the
foreground, but not that it is on the same screen. If the app does not restore its state, the
`large_text` pass audits whatever screen comes back.

## Excluding items for one call

Use these arguments when a finding is a false positive, or an issue you accept, on the screen being
checked. They affect only that call and never change the project's list:

| Argument | Effect |
| --- | --- |
| `exclude_checks=contrast,target_size` | Skips those opted-in checks. They are reported under `exclusions`, not as passed. |
| `exclude_elements=contrast:footer.legal,names:Close` | Leaves out issues of that check on that element id or exact label. The issues stay in the pass's `excludedIssues`. |
| `exclude_reason=...` | Records why, in the report and the reply. |

You can only exclude a check that the project opted in to. Naming any other check is rejected, so a
typo cannot hide a different check.

## Recording and generated tests

A recorded call is an assertion. Generated XCUITest and Espresso tests do not reproduce it yet, so
compiling the plan reports it as an excluded step instead of dropping it. Run it from a flow. The
report keeps every pass, the settings each pass observed, the exclusions and the cleanup result.

## Limits

- Each pass is a native audit of the current screen. It does not establish whole-app conformance or
  that a task can be completed with a screen reader. For those, use `test_voiceover`,
  `test_talkback` and [authored journeys](accessibility-journeys.md).
- Settings are restored when the call ends. If the process is killed mid-call, the device can be left
  in dark mode or at large text. Check `amoo doctor` or reset the setting by hand.
- The [audit policy](accessibility-audit-policy.md) describes a richer rule catalog that skills
  interpret. `check_accessibility` enforces only the list in `amoo.config.json`.
