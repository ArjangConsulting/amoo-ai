# Measuring latency and AI cost

amoo always writes OpenTelemetry traces to a local OTLP/JSON file (see [telemetry.md](telemetry.md));
point `AMOO_TELEMETRY_DIR` at a fresh directory per benchmark run so runs don't mix. Run the same
fixture scenario and versions for every comparison.

Each `execute_tool` span carries duration, success, response and inline-image bytes, image
dimensions and observed element counts; child spans break the time down into device-queue wait,
companion RPCs (with the companion's own `amoo.companion.server_ms`), hierarchy reads and
subprocesses. Spans omit arguments, hierarchy values and secrets.

Use at least 20 repetitions each of screen orientation, form filling, a list-row swipe, a permission
dialog, WebView inspection and recording/export. Separate cold setup from warm execution. Record
platform, device model/OS, toolchain, commit, warm-up policy and successes/skips. Run strict fixture
smoke first so a fast failing tool is not mistaken for an optimization.

The AI client owns model calls and token accounting. Record actual input/output/image tokens,
retries and task success from that client next to these host measurements. Compare full versus
`AMOO_TOOL_PROFILE=drive`, compact queries versus full trees, inline versus artifact-only
screenshots, and known action/assertion sequences through `run_steps`. Bytes are transport measurements, not tokenizer or image-token estimates. Do not
claim a percentage token improvement from byte savings alone.
