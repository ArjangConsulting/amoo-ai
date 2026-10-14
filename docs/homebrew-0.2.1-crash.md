# Homebrew 0.2.1 crash investigation

Observed on macOS 27.2 (26B5112a): the installed universal Homebrew 0.2.1 binary also aborts on
`amoo version` without a companion, printing `freed pointer was not the last allocation`
(SIGABRT, shell exit 134). This is a minimal reproduction independent of app/device state.
The old tag does not implement the `version` subcommand: it falls through to the REPL
and crashes during device discovery. Its supported `--version` still prints 0.2.1.
Thus the reproduction exercises host subprocess discovery, not the newer version handler.
Existing device/MCP crash reports show `swift_task_dealloc` called from SwiftyShell's
`closure #1 in closure #2 in SingleCommandRunner.run()`.

The 0.2.1 source tag resolves to `fac22bf3494f504381f8d53a585e17dd8fbd31f2`;
the working checkout release binary reports version 0.2.0 and compiled commit
`682e1919e7042a540a10f709174e553b3277cd3b`. They are different builds, not an equivalent
release comparison. The tap downloads the universal release tarball (SHA256
`30cb8b26e6bdb11ec15ff87c4fb3669d415541737b4ef79413920374cf950a12`).
The installed prefix does not retain the release toolchain/dependency metadata.
The 0.2.1 source pins SwiftyShell exactly at 0.5.0, while the current checkout requires
0.7.0 or newer (Package.resolved selects 0.7.0). That is a concrete host dependency
mismatch in the component appearing on the crash stack, not a companion protocol mismatch.
The stack implicates host async subprocess execution; it does not establish whether
the compiler, runtime, or dependency caused the allocation failure in isolation.

The concrete replacement is a freshly built current-checkout release executable using
SwiftyShell 0.7.0. A direct comparison on the same host with the same nonexistent device
and unavailable companion endpoint reproduced SIGABRT for both `current_app` and
`describe_screen` on Homebrew 0.2.1. The rebuilt release exited normally with code 1 and
the expected connection-refused error for both commands. It also passed the CLI/MCP
release smoke check, including subprocess-backed discovery. This verifies removal of
the reproduced host crash; successful inspection against a live companion was not
retested in this comparison. The dependency upgrade has not been isolated from other
checkout/compiler changes, so 0.7.0 alone is not claimed as the proven root-cause fix.

Ship 0.3.0 from the verified current source, not by restamping or repackaging the old
0.2.1 executable. `make release-local` builds the replacement at `.build/release/amoo`.
The version string remains the checkout's last stamped value until release stamping;
the compiled commit and resolved dependency identify the tested build. The release
workflow now smoke-tests both CLI inspection commands without a companion as well as
MCP. Its existing macOS architecture checks exercise the arm64 and x86_64 release slices.

Run the minimal XCTest against a specific binary:

```sh
AMOO_RELEASE_REGRESSION_BINARY=/opt/homebrew/bin/amoo \
  swift test --filter ReleaseBinaryRegressionTests
```

The checkout already accepts the documented post-tool `--arg` flags, and both the
0.2.1 source tag and current parser contain that support. Focused parser/schema coverage
protects the full leased invocation. An unknown-argument report cannot yet be reproduced
with the working checkout binary; retain the exact failing argv and executable identity
when investigating it further.
