# Review implementation status

Implements the concrete defects and the selected performance/architecture improvements from the
[September 4 review](review-2026-09-04.md). Changes are grouped into subprocess, runtime, CI, and documentation commits. The historical review records
the original state; this document records the patch and its remaining boundaries.

| Review area | Change |
| --- | --- |
| Session/device routing | Only omitted session IDs use the default driver. Missing/closed IDs fail explicitly. Production bootstrapping leases devices within a server process. |
| Companion exposure | Android now binds IPv4 loopback, matching iOS. Remote deployment is unsupported. |
| Text verification | Ordinary fields require exact equality with bounded polling. Secure-entry metadata crosses the proto boundary; masked changes never claim exact verification. |
| Ambiguous targets | Host mutation/assertion paths require unique matches. Direct companion tap/text paths also refuse ambiguity. Parent constraints survive text re-resolution. |
| Recording durability | Actual idle flush timer, orderly shutdown flush/drain, pending/saved/failed health reporting and safe persistence diagnostics. |
| Recorded secrets | Known secrets are scrubbed across arguments, results, observed selectors and launch metadata using an atomic session snapshot. URL credentials/query values are scrubbed. Explicit fixture values remain usable for codegen. Redacted launch/action values block complete export. |
| MCP contracts | Screenshot/report/assistant fields align with published schemas; numeric/boolean validation rejects invalid values. Smaller drive/record/audit catalogs are available. |
| Concurrency | Cancellable request registry, bounded input frames/tasks, serialized output, per-device operation queues and gRPC deadlines. |
| Codegen recovery | Persisted test intent and context JSON snapshots survive restart; the offline compiler applies the saved context. |
| Coordinates | Convert to points before recording so pixel/normalized swipes associate with the same row as point gestures. |
| App scope | Remove lexical exclusions for time/battery/system labels. Android empty app scope stays empty; parent/scoped resolution avoids unscoped semantic fallback. |
| Audit evidence | Verify frontmost app, scope the observation, return structured findings and per-rule evidence coverage. WebView presence no longer implies unvalidated deep links. |
| CI and quality docs | Add companion builds, strict fixture smoke and opt-in physical qualification. Fix Make pipeline failure propagation. Document actual coverage floors and per-module reporting. |
| AI context and latency | One hierarchy observation for description/suggestions; remove unused screenshot capture. Bound query/history output, offer artifact-only screenshots, shorten skill/instructions and add compact batch execution. |
| Recording scale | Lightweight summary indexes avoid reading historical action payloads for listings; evict older successfully persisted closed sessions from memory. |
| Architecture/test fidelity | Extract SessionCompiler from MCP; preserve complete subprocess requests and true pipeline semantics; name in-memory companion fixture construction explicitly. |
| Measurements | Add response/image byte counts and element counts to telemetry, event trace IDs/timestamps, a p50/p95 summarizer and a reproducible measurement guide. |

## Validation

- Final formatting and `make lint`: zero violations. Vendored checkouts and generated proto sources
  remain excluded from formatting.
- Complete Swift suite: only the same three socket-binding failures present in the baseline remain:
  `USBTunnelTests.testOpenForwardsLocalToDevicePortForSpecificUDID` and
  `TCPReachabilityTests.testReachablePortReturnsTrue` / `testUnusedPortReturnsFalse`.
  The sandbox denies their loopback listeners. This is not a completely green full-suite run.
- Focused regression coverage includes invalid/closed routing, duplicate mutation rejection,
  truncated/delayed/secure text values, cancellation, screenshot schemas, secret leakage,
  offline context recovery, failed persistence, summary indexes, closed-session eviction,
  equivalent coordinate spaces, batch stopping/recording, complete process requests and real pipes.
- Skill validation, documentation links, telemetry aggregation fixture, workflow YAML and embedded
  shell syntax pass. The driving skill entrypoint is 94 lines / 5,226 bytes. These are byte/line
  measurements, not model token measurements.
- iOS companion proto/project generation succeeds. Xcode build verification is blocked by forbidden
  SwiftPM manifest-cache writes and unavailable CoreSimulator services, including a retry with
  writable module/package-cache settings.
- Android companion build verification is blocked by DNS/network access while downloading Gradle
  9.5 (`services.gradle.org`). No fresh emulator or physical-device qualification is claimed.
- Coverage percentages and hosted CI success were not measured in this environment.

## Boundaries and further architectural work

The review includes alternative designs and longer-term product expansion as well as defects.
The patch chooses an idle flush timer and summary indexes; report persistence still rewrites the
full history in batches. A true append-only journal remains a separate storage migration: it must
also retroactively scrub earlier observations when a secret becomes known, recover torn writes,
and preserve offline `report.json` compatibility. Disk artifacts are never automatically deleted.

Screen tokens are hierarchy change hints, not server-owned snapshot references. Atomic
snapshot-handle gestures, cross-process device leases, remote authentication/TLS, a separate
portable plan-domain package and a generated operation registry remain architectural extensions.
Existing schemas and validators are improved incrementally, not replaced by a generated registry.
Security rules that need manifests, signing or attack-scenario evidence report limited coverage;
those stronger checks are not implemented by current-screen inspection.

`run_steps` reduces round trips for known actions/assertions but does not implement rollback or
automatic retries. Companion cancellation can lag host deadlines. Measure actual AI calls and
input/output/image tokens in the intended client before claiming cost savings. See
[benchmarking](benchmarking.md), [current architecture](current-architecture.md),
[support matrix](support-matrix.md) and [MCP usage](mcp-server.md).
