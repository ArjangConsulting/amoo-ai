# Device runtimes

`amoo env up` starts amoo on a simulator or emulator and returns its `runtime_id`, device and
companion port. `amoo env down --runtime-id <id>` stops it. Runtime IDs are optional routing and ownership
credentials for later commands, supplied through `--runtime-id` or `AMOO_RUNTIME_ID`. An id given with
`--runtime-id` that is unknown or expired is an error; a stale `AMOO_RUNTIME_ID` from the environment
is ignored, since it outlives its runtime.

A runtime record tracks a companion's lifecycle. Device access coordination is separate: a kernel
lock prevents simultaneous sessions from controlling the same device and is released automatically
when its process exits or crashes. The in-process `DeviceAccessRegistry` also guards asynchronous
session setup and cleanup. Even `env down --force` respects an active device access lock.

An owner's own calls (`device`, `flow`, `probe`) take no access lock, so they may overlap; the lock
guards devices that have no runtime. `env down` stops a live runtime only when it is given that
runtime's ID (`--runtime-id` or `AMOO_RUNTIME_ID`) or `--force`; an expired runtime may be stopped by
anyone, with `--device`. `--force` also removes the record when the companion could not be stopped.

Installed means that the companion app is installed on the device. Installation alone says nothing
about whether it is running. `env list` and `doctor` probe the companion API and check process identity;
neither a tracking file nor a listening TCP port alone establishes that amoo is running.

| State | Meaning |
| --- | --- |
| `starting` | Startup is in progress and the companion API is not ready yet. |
| `running` | The tracked companion process is alive and its API responds. |
| `unresponsive` | The process remains alive but its API does not respond after startup. |
| `stale` | The process exited, its PID belongs to another process, or an expired record has no responsive companion. |
| `stopped` | The companion was stopped; its runtime record is removed after successful cleanup. |

Read-only diagnostics include stale records without removing them or stopping processes (the one
exception is the one-time migration of previous records, below). Starting a
new runtime retires expired records under the device access lock. Cleanup verifies process identity
before sending signals, so a stale PID cannot terminate an unrelated process. Stopping by device
also finds orphaned companion processes when their runtime record is missing.

Present an owned runtime's ID to `env up` to reuse its reachable companion. Starting without its
credential refuses a device already reserved by another runtime. Unresponsive runtimes must be
stopped before restarting; this avoids leaving duplicate companion processes.

Runtime records are private JSON files under `~/.amoo/runtimes`, overridden by `AMOO_RUNTIME_DIR`.
Setting `AMOO_RUNTIME_DIR` isolates the store: the previous lease directory is neither read nor
migrated unless `AMOO_LEASE_DIR` is also set.
Owner labels can come from `AMOO_RUNTIME_OWNER`. On upgrade, the store migrates previous records,
including expired ones, preserving the device, companion PID, port, dates, boot ownership and app.
Old IDs remain readable for cleanup and are normalized to runtime IDs. Migration defers while an
older session owns the device and continues to report its record. The access lock remains in the
previous shared location so sessions started before an upgrade still block concurrent control.

Init manifests write schema version 2. Reading version 1 converts its saved credentials and process
fields; subsequent writes use only the runtime vocabulary. `init down` can therefore still clean up
companions started before the upgrade.
