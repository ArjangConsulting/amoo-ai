# Measuring latency and AI cost

Set `AMOO_PERFORMANCE_TELEMETRY=1` on the Amoo process and capture stderr to a local JSONL log.
Run the same fixture scenario and versions for every comparison. Summarize the log with:

```bash
python3 scripts/benchmark-telemetry.py /tmp/amoo-benchmark.jsonl
```

Each operation event includes duration, a unique event trace ID, timestamp, success state, response
text bytes, inline image bytes and recorded element count where available. The summary groups by
operation and reports samples, failures, p50 and p95 latency and byte totals. Trace IDs identify
individual events; they are not yet propagated through companion RPCs. Events omit arguments,
hierarchy values, device identifiers and secrets.

Use at least 20 repetitions each of screen orientation, form filling, a list-row swipe, a permission
dialog, WebView inspection and recording/export. Separate cold setup from warm execution. Record
platform, device model/OS, toolchain, commit, warm-up policy and successes/skips. Run strict fixture
smoke first so a fast failing tool is not mistaken for an optimization.

The AI client owns model calls and token accounting. Record actual input/output/image tokens,
retries and task success from that client next to these host measurements. Compare full versus
`AMOO_TOOL_PROFILE=drive`, compact queries versus full trees, inline versus artifact-only
screenshots, and known action/assertion sequences through `run_steps`. Bytes are transport measurements, not tokenizer or image-token estimates. Do not
claim a percentage token improvement from byte savings alone.
