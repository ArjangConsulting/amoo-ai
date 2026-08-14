# API Documentation (DocC)

Amoo's library targets are documented with DocC. Every push to `main` builds a combined
site from all documented targets and publishes it to GitHub Pages.

## Generate locally

```bash
make docs
```

This runs [`scripts/generate-docs.sh`](../scripts/generate-docs.sh), which:

1. Builds a `.doccarchive` for each documented library target with the Swift-DocC plugin.
2. Merges them into one combined archive with `docc merge`, so the site has a single
   cross-module landing page instead of one per target.
3. Writes the result to `.build/docs.doccarchive`.

Open it in Xcode's documentation viewer:

```bash
open .build/docs.doccarchive
```

(`docc preview` isn't the right tool here — it renders a single `.docc` source catalog on
the fly, not a pre-built, merged `.doccarchive`.)

## Documented targets

`scripts/generate-docs.sh` lists the targets explicitly — add a new library target there
when you want it included:

- AmooCore
- CompanionProtocol
- IOSDriver
- AndroidDriver
- ProcessRunner
- GRPCService
- MCPServer
- AuditEngine
- CommandContract
- TestSession
- OllamaClient

`Protos` (generated protobuf code) and the `amoo` CLI executable are intentionally excluded.

## Static hosting build

The GitHub Pages workflow calls the same script with `--static`:

```bash
scripts/generate-docs.sh site --static --hosting-base-path /amoo-ai
```

This additionally runs `docc process-archive transform-for-static-hosting` and writes a
root `index.html` redirect, since the DocC web app does not navigate correctly from a bare
root URL on a static host.
