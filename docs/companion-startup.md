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

## Build modes

- `auto` (default): use release-bundled companion products. In a source checkout without bundled
  products, build when products are missing or sources changed.
- `reuse`: use bundled or cached products, ignoring source changes. Never compile. Missing products
  produce an actionable error.
- `rebuild`: compile the companion from source even when products exist. This mode requires the
  normal development toolchain and a writable source checkout.

For example:

```json
{
  "app_id": "com.arjangconsulting.jot",
  "platform": "ios",
  "device_hint": "<simulator UDID>",
  "build_mode": "reuse"
}
```

Simulator boot and companion compilation run concurrently, joining before companion launch.
Android APK preparation runs concurrently with emulator selection/boot and joins before APK
installation. An existing companion API is reused when compatible with the selected device.
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
paths are validated after relocation. Release CI transfers a tar archive to preserve executable
permissions and symbolic links, and includes the products in the macOS/Linux distributions.
