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
