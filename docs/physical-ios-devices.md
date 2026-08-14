# Physical iOS Devices

Simulators need no extra tooling. Driving a **physical** iOS device additionally requires
the `iproxy` binary:

```bash
brew install libimobiledevice
```

`iproxy` itself ships in the `libusbmuxd` formula, which `libimobiledevice` pulls in as a
required dependency and links onto your `PATH` — so the command above is all you need. If
you want only the tunnel and none of the `idevice*` utilities, `brew install libusbmuxd` is
a smaller equivalent. Confirm with `which iproxy`.

`iproxy` forwards a port on your Mac to a port on the USB-connected device. It is needed
because a simulator shares `localhost` with the host — so the companion is directly
reachable — while a real device does not. Android solves this with the built-in
`adb forward`; Apple ships no equivalent, as `xcrun devicectl` has no port-forwarding
command at all. Without `iproxy` there is no route from the host to the companion running
on the device.

Amoo starts and stops the tunnel itself; you only need the binary installed. Check your
setup with:

```bash
swift run amoo preflight --platform ios
```

`ios.devicectl` and `ios.iproxy` report `WARN` rather than `FAIL` when missing, since
simulator-only workflows never use them.

Two further requirements for real hardware:

- The device must be paired and trusted — verify with `xcrun devicectl list devices`.
- The XCUITest companion runner must be signed with a provisioning profile valid for that
  device. Simulators skip code signing entirely.

One capability is simulator-only: `setPermission`. `simctl privacy` can grant and revoke
TCC permissions, and `devicectl` has no counterpart, so on a device Amoo fails that call
explicitly rather than pretending it worked. Grant permissions manually in Settings.

## Current Constraint

The repo-root iOS e2e flow is simulator-only today.

Connected physical devices are detected and reported, but this flow still depends on:

- companion access over `127.0.0.1:22087`
- `simctl` for host-side iOS device actions

So physical-device fallback is not implemented yet for `scripts/run-e2e.sh`.
