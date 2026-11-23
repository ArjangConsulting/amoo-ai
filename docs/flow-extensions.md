# Flow extensions

A flow step whose tool is `prefix.step` is run by an outside program, `amoo-ext-<prefix>`, instead of by
amoo. `moq.select_variant` is the step `select_variant` of `amoo-ext-moq`. amoo knows nothing about what an
extension does: it describes it, starts it for the run, hands it its steps, and ends it. That lets a flow
drive a mock server, a feature-flag service or a backend fixture between device steps, over the same
companion connection, without amoo depending on any of them.

```json
{ "platform": "ios", "steps": [
  { "tool": "start_session", "arguments": { "app_id": "com.example.app" } },
  { "tool": "moq.select_variant", "arguments": { "endpoint": "GET /v1/me", "variant": "server-error" } },
  { "tool": "tap_element", "arguments": { "id": "profile.refresh" } },
  { "tool": "moq.assert_request", "arguments": {
      "endpoint": "GET /v1/me", "times": 1, "headers": { "authorization": { "scheme": "Bearer" } } } } ] }
```

An extension a flow needs only for its launch environment (a mock-server session, with the app then
checked through its own UI) has no step to name. List it at the top of the flow, and it is started and
ended like one a step uses:

```json
{ "platform": "ios", "extensions": ["moq"], "steps": [ … ] }
```

Prefixes and step names are lowercase ASCII letters, digits and `_`, starting with a letter. Built-in tools
never contain a dot, so they cannot collide. Arguments of an extension step may be JSON objects and arrays
as well as strings, numbers and booleans; `${name}` resolves in every string inside them. Built-in tools
still take scalar arguments only.

## Finding the program

amoo looks for an executable named `amoo-ext-<prefix>` in each directory of `AMOO_EXTENSION_PATH`
(colon-separated), then of `PATH`. Point `AMOO_EXTENSION_PATH` at a local build to use it without
installing it. A flow that uses a missing extension fails before its first step.

## Protocol (version 1)

amoo runs `amoo-ext-<prefix> <verb>` with one JSON object on stdin and reads one JSON object from stdout.
stderr is free for the extension's own logging. A non-zero exit, or stdout that is not a JSON object, is a
failure. Each call may take 60 seconds, or the step's `timeout_ms` plus 10 seconds when that is longer.

Every request has:

| Field | Value |
| --- | --- |
| `protocol` | `1` |
| `verb` | the verb, also passed as the first argument |
| `run` | `{id, flow, output_dir, platform, device_id}` for this flow run on one device (absent fields are omitted) |
| `state` | the last `state` this extension replied with in this run, or `null` |

Every reply has `protocol: 1`; a reply with another version is rejected. Any reply may also carry:

| Field | Effect |
| --- | --- |
| `state` | Any JSON. Replaces the state amoo sends back on the next call, unread. An extension keeps its per-run data here (a session id, marks) instead of running as a background process. |
| `launch_environment` | Object of strings. Merged into the `environment` of every later `start_session` and `device_launch_app` step, after the step's `${name}` references resolve; a key the step sets itself wins. |
| `vars` | Object of strings. Available to later steps as `${name}`, replacing a flow variable of the same name. |

### Verbs

| Verb | When | Request adds | Reply adds |
| --- | --- | --- | --- |
| `describe` | Once per run, before anything else, for each extension the flow declares or a step uses | — | `steps`: the step names it offers (strings, or `{name}` objects). A flow step it does not list fails the run before any step runs. |
| `flow_start` | Once per run, before the first step | `vars`: the flow's variables | `ok`. `false` fails the run before any step runs. |
| `step` | For each of its steps | `step: {tool, name?, number, arguments}`; `tool` is the part after the dot | `ok`, `message` (the step's line in the output), `result` (any JSON, saved in `report.json`) |
| `flow_end` | After the last step, whenever `flow_start` succeeded | `passed`: whether the run passed | `ok`. A failure is logged and does not change the run's result. |

`amoo flow --devices` runs one flow per device, so each device gets its own `run.id`, `flow_start` and
`flow_end`: an extension that opens a resource per run (a mock-server session) keeps parallel devices apart.

Test generation does not yet ask extensions for code; a planned `emit` verb will. Until then
`generate plan --from-flow` leaves extension steps out of the compiled plan with a warning, and `generate test`
refuses that plan as incomplete unless `--allow-incomplete` is passed, so a mock step is never silently
missing from a generated test.
