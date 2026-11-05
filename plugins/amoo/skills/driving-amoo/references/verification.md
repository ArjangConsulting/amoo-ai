## Discover once, verify complete coverage

Use the pinned binary's `amoo capabilities --command device --platform <platform>` or MCP
`get_capabilities` once per binary/runtime. Query `tool=<name>` (CLI `--tool <name>`) only for an
unfamiliar operation. Cache the version, identity and schema; rediscover after a binary change or
provider change. Older binaries without discovery fall back to their own help. `--runtime-id` and
`AMOO_RUNTIME_ID` identify controlled CLI runtimes; `--lease` is not a device flag.

Prefer typed MCP arguments. For CLI selectors containing spaces, use an argv array or
`amoo device --runtime-id <id> --json find_elements --arguments-json @arguments.json`, where the
file is an object such as `{"label":"Account settings","limit":12,"response_mode":"compact"}`.
Do not concatenate selectors into shell commands. Validation errors name the argument and example;
correct the invocation before retrying. Do not restart a session to fix an argument or selector.

Supply exact launch configuration at startup. Check `startup.launch.fresh_process` and
`environment_delivery` (or `launch` on `device_launch_app`); unknown delivery is missing evidence.
iOS uses process environment; Android uses Intent extras, requiring app support. Host delivery does
not establish that the app consumed a flag. Installation, foreground identity, semantic readiness
and rendered readiness are separate results. A reused process cannot acquire a new environment.
For an owned stale/unresponsive CLI runtime, retry `env up --platform <platform> --runtime-id <id>`;
include the build only when reinstalling. This preserves runtime identity and data. Do not release
ownership merely to recover a companion. A managed MCP session still follows its scoped recovery.

Declare every required check in `start_session checks` and attach `check_id` to explicit assertions.
Read `get_verification_report` before closing and retain its per-check evidence. Unsupported native
state is blocked coverage, not a failed element lookup or a pass. Successful gesture dispatch is
not an assertion. A selector miss returns identity and bounded available controls: confirm the target,
try a stable ID or scoped text, and inspect the relevant saved screenshot before declaring navigation
blocked. A content error does not block independent navigation; verify those controls separately.

Use bounded `find_elements`, `response_mode=compact`, and `run_steps result_mode=compact` for known
sequences. Use `continue_on_error=true` only when later steps are independent of earlier success.
Keep decision-dependent steps separate. Save screenshots with `output`, `return_image=false`, and
an appropriate `scale`; inspect relevant screenshots for visual/layout checks. Screen tokens detect
semantic changes, not pixel equivalence; incremental hierarchy diffs are not advertised. Reuse the
same runtime/session during ordinary queries and app reinstall. Metrics report response bytes,
image dimensions, client calls, operations, setup/recovery milliseconds and completed checks.
Report measured values; do not infer model-token savings. The caller chooses the cheapest reliable
model per spawn; exploratory navigation and screenshot interpretation still require adequate reasoning.

Derive overall status from all required checks: `fail` if an observed requirement failed; `pass`
only if every required check passed; `partial` if some checks completed and coverage remains missing;
`blocked` if no requested check completed. Retain blocked and untested reasons and evidence per check.
In the compact AgentRunReport version 2 transport, passed/failed checks are assertions and blocked/
untested checks remain in `coverage.notEvaluated` with explicit reasons. Use `verdict=notAssessed`
for partial coverage. Never report overall pass for an incomplete run.

Keep one caller UUID in `run_id` across every attempt, or set `AMOO_RUN_ID` before starting each
CLI/MCP process. Successful sessions inherit their startup run UUID. Call `get_run_telemetry`
with that UUID to aggregate failed startup, recovery and unfinished calls across sessions and
processes. The current report request is excluded from its snapshot; subsequent reports include it.
`unfinished_calls` includes active requests and requests abandoned by a terminated process.
`recording_health=incomplete` means the totals may omit unreadable or unwritten records.
Text payload bytes exclude image blocks; wire response bytes include encoding overhead and
base64 images. Inline image bytes/pixels and saved evidence bytes/pixels are separate measurements,
not token estimates. `model_token_usage=null` means the device tool has no provider token usage.

Delegated checks default to `output=<path> return_image=false`. Return selected thumbnail or
contact-sheet paths for review; use `amoo shots montage <evidence-dir>` to combine saved captures.
Inspect every screenshot needed to assess layout. Pause playback through an app control before
stable inspections unless motion is the requirement, and replay supplied recorded navigation flows.
Treat `capture_suspect=true` as inconclusive image evidence. Check capture_analysis, foreground_app_id,
screen_state and viewport together, then recover the device or recapture before diagnosing rendering.
Pixel analysis may be unavailable on hosts without an image decoder; that is never a clean capture verdict.
After a fold or display change, read posture, viewport, lock and foreground identity together and
assert the requested app state. A verified hinge transition does not verify the app or unlock the screen.
Reports preserve `outcome_status`: `dispatched`, `target_state_confirmed`, `target_state_mismatch`,
or `inconclusive`. Explicit assertions or exact field readback confirm target state; required coverage still needs authored assertions. Selector-miss candidates
are nearby text matches within the requested parent scope, with roles; a subtitle may expose one
action per word instead of a sentence-level label. These suggestions never weaken the assertion.

Quality and latency come first; keep semantic postconditions when reducing model calls. Prefer
get_screen_context and scoped find_elements to full trees or screenshots, and use semantic
postconditions rather than a screenshot after a tap. For transient UI, put the action and an immediate
take_screenshot in one run_steps call with output, return_image=false, and settle_timeout_ms=0.
Use check_effect=false on a triggering tap_element so its post-tap hierarchy reads do not consume
the capture window. For tighter timing, use a coordinate tap from freshly queried geometry to avoid
tap_element's foreground-app observation too. Capture first, then assert the eventual outcome;
batching removes client round trips but cannot guarantee a subsecond capture. Use a cold fixture
when cached data would skip the loading state.
Save screenshots without inline images; analyze pixels locally with available Python/ffmpeg tools
(diffs, bounds, centroids), and view only a small crop when visual interpretation is necessary. Keep focused
inspections to 20 actions where the task allows, and reuse a recorded flow.json via amoo flow rather
than re-driving it. Use run_steps for
known action/assertion/observation sequences (up to 20 steps, stops on failure); inspect between
steps that need a new decision. Prefer scoped queries over full trees. Configure AMOO_TOOL_PROFILE
as drive, record, or audit before MCP startup to load a smaller task-specific tool catalog.

Drag and drop with `drag` (source `id`/`label`, target `to_id`/`to_label`); zoom with `pinch`
`scale=2` (in) or `0.5` (out) on an element, or with no target for the whole app. Coordinate ends
work live but are excluded from generated tests.

A dispatched gesture does not prove a business outcome. Verify mutations with the relevant
semantic assertion. `set_text` reports exact, masked_change, or unverified; a masked change
cannot prove the secret's exact value. Use a subsequent app-level result where appropriate.

Screenshot output includes pixels, gesture points, and scale. Use a modest scale for visual
inspection. Delegated checks default to output=<path> return_image=false; return selected thumbnail
or contact-sheet paths for review. Pause playback for stable checks and reuse recorded navigation.
Check capture_suspect and device state; retain get_run_telemetry with one run_id across every attempt.
