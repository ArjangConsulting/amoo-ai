# AI-driven verification

Amoo uses the same typed tool catalog for MCP discovery, CLI argument validation, CLI tool help,
and machine-readable schema queries. Discover once per binary/runtime, then query individual
contracts as needed:

```sh
amoo capabilities --command device --platform ios
amoo capabilities --tool find_elements
amoo capabilities --runtime-id <runtime>
```

The equivalent MCP tool is `get_capabilities`, with optional `tool`, `platform`, and `session_id`.
Discovery does not boot, install, launch, or acquire a device. It reports the binary version,
binary identity, invocation options, assertion support, and an optional runtime identity. CLI
runtime state is labeled `state_source=stored`; use `device_health` or scoped doctor for live health.
Platform defaults describe the standard provider. A managed session reports its actual inspector
configuration and active catalog availability; custom providers default to unknown support. Conditional support requires the
applicable property on the matched element. Unsupported native state, missing elements, and
observed assertion mismatches have distinct result fields.

## Structured invocation

Use typed MCP tools directly. CLI callers can pass argv without a shell, or save arguments as JSON:

```json
{"label":"Account settings","limit":12,"response_mode":"compact"}
```

```sh
amoo device --runtime-id <runtime> --json find_elements --arguments-json @arguments.json
amoo device --runtime-id <runtime> find_elements 'label=Account settings'
```

`--arguments-json` accepts an object or `@path`, up to 64 KiB. Arrays/objects retain their JSON
representation for existing structured tools such as `run_steps`. Duplicate argument keys across
invocation sources, nulls, unknown keys, invalid values and missing required arguments are rejected.
Machine errors identify `argument`, give an `example`, and report `dispatch_status=not_dispatched`.
All batch steps are validated before the first mutation. Runtime ownership remains mandatory.

`amoo device --help` renders tool signatures from the installed MCP definitions rather than a
second hand-maintained argument list. `--runtime-id` and `AMOO_RUNTIME_ID` are the supported CLI
ownership credentials. The historical `--lease` spelling is rejected.

## Startup and recovery

`start_session.startup` separates installation, launch receipt, semantic readiness and rendered
readiness. `device_launch_app.launch` returns the same launch receipt, and `env up.app` retains it.
Receipts contain the app identity, `fresh_process`, environment delivery mechanism and key names;
they do not expose environment values. Standard iOS launches replace the running process and
deliver process environment. Configured Android launches force-stop before starting and deliver
Intent extras, including argument-only launches. App support is required to consume those extras.
Unknown providers report null fresh-process status and unknown delivery. Host delivery does not
establish that the app consumed a flag or reached a business postcondition.

A hierarchy containing only its root remains semantically empty. Startup reports unverified
semantic readiness after its bounded wait; rendered readiness stays unverified until appropriate
evidence is inspected. Empty observations and selector misses include foreground/target identity,
bounded recovery guidance, and, for a scoped miss, at most twelve available controls. They leave
navigation status unassessed. A content error can coexist with functioning navigation.

An explicitly owned stale or unresponsive CLI runtime can recover in place:

```sh
amoo env up --platform ios --runtime-id <runtime> --json
amoo env up --platform ios --runtime-id <runtime> --app <App.app> --app-id <id> --json
```

Recovery preserves the runtime ID, endpoint, device and app data, and reports `recovered` and
`recovery_ms`. Only the verified companion belonging to that runtime is stopped. Active device
locks and other owners still prevent recovery. Failed stop/start/preparation retains ownership
for diagnosis or retry. MCP session IDs remain process-owned; forced MCP closure/reset remains
the recovery path for an unusable managed session.

## Required coverage

Declare every required check at managed startup:

```json
{"app_id":"com.example.app","platform":"ios","checks":["content","navigation","checked"]}
```

Attach `check_id` to an explicit assertion. Successful dispatch, observations and screenshots do
not complete a check. A native property unsupported by the provider/element yields blocked
coverage; an observed property mismatch yields failed coverage. Unattempted checks remain untested.
Each check retains an outcome, reason, and reference to its recorded action evidence. The ledger,
assertion payloads and metrics persist in `report.json`; ordinary app reinstall does not reset them.

`get_verification_report` returns compact coverage and measured costs, including after session
closure. `end_session` also returns the derived verification status when checks were declared.

| Overall status | Rule |
| --- | --- |
| `fail` | An observed required assertion failed |
| `pass` | Every required check passed |
| `partial` | Some required checks completed and coverage remains missing |
| `blocked` | No required check completed, including an empty requested set |

The compact external `AgentRunReport` remains version 2. Passed/failed assertions populate
`coverage.evaluated`; blocked/untested checks populate `coverage.notEvaluated` with reasons.
`validate-report` compares against the caller's original IDs and rejects an inconsistent overall
status, including partial coverage submitted as pass or blocked. `done` is reserved for observations
without required verification checks. Sealed evidence binds content and scope; a report validator
cannot independently establish the meaning of arbitrary images or agent-authored evidence.

## Compact execution and measurements

`find_elements` remains paginated and bounded. `response_mode=compact` removes duplicated human
text and redundant `bounds`/`semantics` objects, retaining identity, state, values, hit points and
pagination. Explicit assertion proof fields remain identical in full and compact modes.

`run_steps` retains its default stop-on-error behavior and twenty-step limit. Its default
`result_mode=compact` includes assertion proof, error classifications, screenshot paths and
dimensions. `result_mode=full` retains full structured results and content. Set
`continue_on_error=true` only for independent steps; it never converts an error into success.
Batch results distinguish attempted, successful, failed and unattempted operations.

Screenshots support `scale`, `output`, and `return_image=false`. Results report actual decoded
dimensions when available, saved paths, byte counts and scaling status. Unavailable scaling keeps
the original image and says so. Screen tokens support semantic change assertions; hierarchy deltas
are not advertised. Pixel review and model choice remain agent guidance.

Metrics count serialized executor MCP result payload bytes, including base64 for inline images,
excluding JSON-RPC envelopes and server catalog annotations. `clientCalls` counts external calls; `operations` counts executed device
operations, including individual batch steps. Raw inline image bytes and saved image bytes are
separate, and image dimensions are measured per capture. Setup and app recovery operations use
monotonic milliseconds. A verification-report response contains metrics through preceding calls;
the next snapshot includes that report call. These are host measurements, not model-token estimates.

Legacy key=value invocations, full responses and stop-on-error batches remain supported. Validation
now rejects ignored arguments; migrate callers to the discovered schema. Existing session reports
without coverage/metrics still decode. New launch-reporting and inspector-provider protocols have
defaults for custom drivers, which report unknown guarantees rather than assuming support.

## Regression evidence

`VerificationReliabilityTests` exercises multiword selectors, recovery diagnostics, unsupported
checked state, independent navigation after a content failure, coverage persistence, and equivalent
full/compact assertions. `StructuredVerificationTests` covers CLI JSON/argv selectors and validation
before device access. `DeviceRuntimeRecoveryTests` covers reinstall/recovery with stable identity,
active ownership locks and failed cleanup. `AgentReportValidationTests` rejects partial pass claims.
The simulator/ADB launch tests check fresh-process command ordering and environment propagation;
`ScreenshotScalerTests` verifies a saved 200×100 image becomes 100×50 without inline image output.

The paired verification fixture measures full sequential calls versus compact queries plus batching
on the same binary and deterministic driver. It is not a replay of a live application run. Both
execute four device operations and complete two of three required checks: content fails, navigation
passes, and checked state remains blocked. The test prints exact payload bytes, external call counts,
setup/recovery timings and coverage for review. No model-token savings are inferred.

The measured fixture on the implementation build produced the following result payloads:

| Measure | Full sequential | Compact query + batch |
| --- | ---: | ---: |
| Result payload bytes | 29,235 | 12,934 |
| Client calls including startup | 5 | 3 |
| Device operations | 4 | 4 |
| Completed required checks | 2/3 | 2/3 |
| Scenario result | fail | fail |

Payload bytes fell 55.76%, with equivalent assertions. A separate continuation regression increased
completed coverage from 1/3 to 2/3 after a content failure; the remaining unsupported check stayed
blocked and the overall observed failure remained fail. Injected setup/recovery clocks measured
0 ms; these fixtures establish instrumentation and correctness, not real-device speedups.
