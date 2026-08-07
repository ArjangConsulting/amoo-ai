import CompanionProtocol
import IOSDriver
import ProcessRunner

/// Builds an ``IOSDriver`` backed by whichever host toolchain matches `deviceID`.
///
/// A device identifier alone doesn't say whether it names a simulator or real hardware,
/// so this resolves it against the connected-device list before choosing a backend. The
/// check is skipped for `"booted"`, which only ever means a simulator.
///
/// Note this only selects the *host* backend. A physical device also needs the companion
/// reachable over a `USBTunneling` forward — the simulator's shared localhost has no
/// equivalent on real hardware.
func makeIOSDriver(
    companion: any CompanionClient,
    deviceID: String,
    processRunner: any ProcessRunner = SystemProcessRunner()
) async -> IOSDriver {
    let selector = DeviceSelector(processRunner: processRunner)
    guard await selector.isPhysicalDevice(deviceID: deviceID) else {
        return IOSDriver(companion: companion, deviceID: deviceID)
    }
    return IOSDriver.physicalDevice(companion: companion, deviceID: deviceID)
}
