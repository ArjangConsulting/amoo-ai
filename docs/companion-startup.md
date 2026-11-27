# Companion startup

Stopped amoo archives include prebuilt iOS simulator and unsigned physical-device test products,
and both Android companion APKs. `amoo env up` selects a device, prepares the companion, optionally
installs and launches the app under test (`--app`, `--app-id`), and returns a runtime ID.

## Progress

`amoo env up` returns once the companion answers. Its `--json` report says what the companion start
did (`companion.phases`: `check`, `build`, `install.app`, `install.test`, each with an outcome such
as `cached` or `reused`) and how long each step took (`timings_ms`); the companion log path is in
`log`. A Studio session reports its startup through
`session_startup_status`: recent stages, elapsed time, and whether it is pending, ready or failed.
Relay that to the user; do not start a second runtime while the first is still starting.

## Starting never builds

Starting a device (`env up`, `flow`, `device`, `companion start`, `start_session`) never compiles a
companion. It installs the newest build that already exists, either the local build or the packaged
`prebuilt/` products. When none exists it fails at once and names the command that builds one.

When that build is older than its sources, the start goes ahead and prints one warning with both
dates. `env up --json` then reports the `check` phase as `stale` (`current` otherwise), and `build`
is `prebuilt` or `cached`. A local build counts as stale when its recorded source fingerprint no
longer matches and a source file is newer than the build. In a source checkout, packaged `prebuilt/`
products are stale when a source file is newer than they are. A release install's prebuilt ships
with its sources and is never reported stale.

Compiling is explicit:

- `amoo companion build --platform ios|android|macos` builds from the sources. It skips a build that
  is already current unless `--force`. The next start installs the result, replacing an older
  companion running on an Android device.
- `make companion-build` builds both, and so do `make debug-local` and `make release-local`. Whoever
  builds amoo from a checkout therefore leaves current companions for every session to install.
- `start_session` with `build_mode: "rebuild"` compiles before launching.

Build modes for `start_session`:

- `auto` (default): newest existing build, local or packaged. Warn when stale.
- `reuse`: prefer packaged products and never report them stale.
- `rebuild`: compile from source first. This needs the development toolchain and a writable source
  checkout.

For example:

```json
{
  "app_id": "com.arjangconsulting.jot",
  "platform": "ios",
  "device_hint": "<simulator UDID>",
  "build_mode": "reuse"
}
```

With `build_mode: "rebuild"`, simulator boot and companion compilation run concurrently and join
before companion launch; Android APK preparation runs concurrently with emulator selection/boot. An existing companion API is reused when compatible with the selected device.
Amoo does not compile the app under test; `build_path` supplies an already built `.app` or `.apk`.

## Physical iOS devices

Prebuilt device products need signing for the user's development team and device. Configure these
variables in the environment of the shell that runs `amoo env up`:

- `AMOO_IOS_SIGNING_IDENTITY`: a development signing certificate available in the keychain.
- `AMOO_IOS_HOST_PROFILE`: the development provisioning profile for `com.amoo.companion`.
- `AMOO_IOS_RUNNER_PROFILE`: the profile for `com.amoo.companion.uitests.xctrunner`.

Both profiles must include the device UDID. Signing happens on a writable copy under
`~/.amoo/signed-companions`, preserving installed release products. Nested executable bundles are
signed before the host and test runner. Xcode then installs and launches the signed test products
using `test-without-building`; this path does not compile the companion. Xcode, a trusted device
with Developer Mode enabled, and the existing USB tunnel tooling are still required.

## Release packaging

`scripts/package-companions.sh` builds simulator products for arm64 and x86_64, device products for
arm64, and Android APKs. Simulator products receive ad hoc signatures. The products' `.xctestrun`
paths are validated after relocation.

Android packaging builds the Release app and instrumentation APKs with R8 and signs both with the
same Android test key. The packaged APKs use the existing `app-debug*.apk` filenames expected by
the CLI and Homebrew tap. The instrumentation APK contains the gRPC server and generated protobuf
code. Its shrinker rules preserve the runner entry point that the CLI invokes by class name. The
app APK preserves the shared Kotlin standard library's binary interface for the instrumentation
runner.

Release CI transfers a tar archive to preserve executable
permissions and symbolic links, and includes the products in the macOS/Linux distributions.
