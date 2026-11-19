## Verify complete coverage

Read a tool's schema once per binary with `amoo capabilities --tool <name>`; `amoo device` with no tool
lists them all. For selectors containing spaces use `--arguments-json @args.json`, for example
`{"label":"Account settings","limit":12}`; never concatenate selectors into shell commands. A
validation error names the argument: fix the call rather than retrying it.

**Launch.** Pass the exact launch configuration on `device_launch_app` (or `env up --launch`). Its
`launch` receipt reports `fresh_process`, `environment_delivery` and `arguments_delivery`; unknown
delivery is missing evidence. iOS delivers process environment and arguments; Android delivers Intent
extras, which the app must read. Delivery does not prove the app consumed a flag, and a reused process
cannot acquire a new environment.

**Checks.** Derive the result from every requested check: `fail` if an observed requirement failed;
`pass` only if every one passed; `partial` if some completed and coverage is missing; `blocked` if none
completed. Unsupported native state is blocked coverage, never a pass. A gesture's dispatch is not an
assertion. Use `precondition=true` on setup assertions: a mismatch blocks coverage rather than proving
a product defect. A selector miss returns nearby candidates: confirm the target, try a stable ID or
scoped text, and look at the saved screenshot before calling navigation blocked. A content error does
not block independent navigation.

**Assertion results.** A failed assertion says what it last observed (`[id] label visible=… value=…`).
`tap_element` with `expect_*` reports `expected_effect_met` and `expectation_status` (`met`, `not_met`,
`already_satisfied`, `unverified` with `expectation_error`); in a flow an unmet expectation fails the
step. `set_text` reports `exact`, `masked_change` or `unverified`; a masked change cannot prove a
secret's value.

**Cost.** Prefer `get_screen_context` and scoped `find_elements` to full trees or screenshots. Batch a
known sequence of actions and assertions with `run_steps` (up to 20 steps, stops on failure); keep
decision-dependent steps separate. Keep one `run_id` (or `AMOO_RUN_ID`) across attempts; `amoo usage
report` aggregates calls, bytes and timings. Report measured values; do not infer token savings.

**Screenshots.** Save with `output=<path>`; images are not returned inline unless asked for. Return
selected thumbnails or an `amoo shots montage <dir>` contact sheet for review. Pause playback before
stable captures. Treat `capture_suspect=true` as inconclusive, and read `screen_state`,
`foreground_app_id` and the viewport before diagnosing rendering. After a fold or display change,
assert the app state: a verified hinge transition does not verify the app. For transient UI, take the
screenshot with `settle_timeout_ms=0` straight after the tap (`check_effect=false` on that tap), then
assert the eventual outcome; use a cold fixture when cached data would skip a loading state.

**Gestures.** `drag` takes a source (`id`/`label`) and target (`to_id`/`to_label`); `pinch` takes
`scale` (2 in, 0.5 out) on an element or the whole app. Coordinate ends work live but are excluded from
generated tests. Verify every mutation with the relevant assertion.
