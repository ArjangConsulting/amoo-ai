import AmooCore
import AndroidDriver
import CompanionProtocol
import IOSDriver
import MCPServer
import ProcessRunner

extension DeviceCommandOptions {
    func acquireDeviceAccess(store: DeviceRuntimeStore = DeviceRuntimeStore()) throws -> DeviceAccessLock? {
        try acquireRuntimeDeviceAccess(deviceID: deviceID, runtimeID: runtimeID, store: store)
    }
}

func makeDeviceToolExecutor(_ options: DeviceCommandOptions, driver: any PlatformDriver) -> DriverToolExecutor {
    DriverToolExecutor(
        driver: driver,
        foreignBuildDetector: ForeignBuildDetector(),
        webInspector: makeWebInspecting(processRunner: SystemProcessRunner()),
        defaultPlatform: options.platform,
        defaultDeviceID: options.deviceID
    )
}

func makeDeviceCommandDriver(
    _ options: DeviceCommandOptions,
    companion: GRPCCompanionClient
) async -> any PlatformDriver {
    switch options.platform {
    case .ios:
        await makeIOSDriver(companion: companion, deviceID: options.deviceID ?? "booted")
    case .android:
        AndroidDriver(companion: companion, inspectionMode: .productionDefault(), serial: options.deviceID)
    }
}

/// Refuses a device another session controls, then guards a free device against simultaneous
/// control. The runtime's owner takes no lock: its runtime already is the exclusion, and its own
/// calls (a `screenshot` during a `flow`) may overlap. Returns `nil` when nothing needs holding.
func acquireRuntimeDeviceAccess(
    deviceID: String?,
    runtimeID: String?,
    store: DeviceRuntimeStore = DeviceRuntimeStore()
) throws -> DeviceAccessLock? {
    let presented = presentedRuntime(flag: runtimeID, store: store)
    try enforceDeviceAccess(deviceID: deviceID, runtime: presented, store: store)
    guard let deviceID, deviceID != "booted" else { return nil }
    if case .owned = store.access(deviceID: deviceID, presenting: presented) {
        return nil
    }
    let access = try DeviceAccessLock(deviceID: deviceID, store: store)
    try enforceDeviceAccess(deviceID: deviceID, runtime: presented, store: store)
    return access
}
