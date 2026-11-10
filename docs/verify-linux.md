# Verifying the Linux build locally

CI's `Build & Test (Linux)` job (`.github/workflows/ci.yml`) runs in the `swift:6.4-noble`
container. Reproduce it locally with Docker instead of guessing at platform gating — a
`#if canImport(Darwin)` / `#if os(Linux)` split that looks right can still leave a symbol
undefined or a test asserting on an empty result:

```bash
make verify-linux                    # build --product amoo + test (mirrors the CI job)
./scripts/verify-linux.sh build      # build only
./scripts/verify-linux.sh test       # test only (add --filter by editing, or use `shell`)
./scripts/verify-linux.sh shell      # interactive shell in the container
```

It builds into `.build-linux/` (gitignored) so the host `.build/` is left alone, and skips
`IntegrationTests` + `CLIQualityCoverageTests` exactly as CI does. Run it after any change to
platform-conditional code (`ProcessRunner`, anything with `#if os`/`canImport`) before pushing.
