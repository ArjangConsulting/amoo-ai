// swiftlint:disable multiline_arguments
import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import MobileDevices
import ProcessRunner
import TestSession

/// Production `SessionBootstrapper`: selects a device, ensures the companion is
/// running on that device, opens a gRPC connection, installs + launches the
/// app under test, and waits for the first stable screen.
struct DefaultSessionBootstrapper: SessionBootstrapper {
    static let deviceAccess = DeviceAccessRegistry()
    let iOSCompanionManager: any IOSCompanionManaging
    let androidCompanionManager: any AndroidCompanionManaging
    let processRunner: any ProcessRunner
    let usbTunnel: any USBTunneling

    /// How many seconds to wait for a hierarchy with app content after launch.
    let screenStabilizationTimeoutSeconds: Double
    /// Cross-process device runtimes (`amoo env up`); injectable so tests never read `~/.amoo`.
    let runtimeStore: DeviceRuntimeStore
    /// The `--port` an MCP server was started with, used for iOS sessions that name no port of
    /// their own. `nil` derives a stable per-simulator port instead (see `IOSCompanionPort`).
    let serverPort: Int?

    init(
        iOSCompanionManager: any IOSCompanionManaging,
        androidCompanionManager: any AndroidCompanionManaging,
        processRunner: any ProcessRunner = SystemProcessRunner(),
        usbTunnel: any USBTunneling = IProxyTunnel(),
        screenStabilizationTimeoutSeconds: Double = 10,
        runtimeStore: DeviceRuntimeStore = DeviceRuntimeStore(),
        serverPort: Int? = nil
    ) {
        self.serverPort = serverPort
        self.runtimeStore = runtimeStore
        self.iOSCompanionManager = iOSCompanionManager
        self.androidCompanionManager = androidCompanionManager
        self.processRunner = processRunner
        self.usbTunnel = usbTunnel
        self.screenStabilizationTimeoutSeconds = screenStabilizationTimeoutSeconds
    }

    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
        let clock = ContinuousClock()
        let bootstrapStart = clock.now
        await StartupProgress.report("Selecting device")
        let selector = PlatformDeviceSelector(processRunner: processRunner, runtimeStore: runtimeStore)
        async let androidBuild: Bool = prepareAndroidBuild(request)
        let available = try await selector.selectDevice(
            hint: request.deviceHint,
            platform: request.platform,
            deferIOSBoot: true
        )

        let deviceKey = switch available {
        case let .ios(device): "ios:\(device.udid)"
        case let .android(serial, _): "android:\(serial)"
        case .macos: "macos:\(MacHostBackend.deviceID)"
        }
        // Cross-process: a device another session controlled via `amoo env up` is off limits unless
        // this server was started with that runtime in AMOO_RUNTIME_ID.
        try Task.checkCancellation()
        let accessLock = try DeviceAccessLock(deviceID: available.deviceID, store: runtimeStore)
        runtimeStore.reapIfExpired(deviceID: available.deviceID)
        try enforceDeviceAccess(
            deviceID: available.deviceID,
            runtime: presentedRuntime(flag: nil, store: runtimeStore),
            store: runtimeStore
        )
        let installAndroidBuild = try await androidBuild
        let owner = try await Self.deviceAccess.acquire(deviceKey)
        do {
            return try await bootstrap(
                request,
                available: available,
                start: bootstrapStart,
                ownership: SessionOwnership(deviceKey: deviceKey, owner: owner, accessLock: accessLock),
                installAndroidBuild: installAndroidBuild
            )
        } catch {
            await Self.deviceAccess.release(deviceKey, owner: owner)
            throw error
        }
    }

    // Keep resource acquisition and rollback in one linear lifecycle.
    // swiftlint:disable:next function_body_length
    private func bootstrap(
        _ request: SessionBootstrapRequest,
        available: AvailableDevice,
        start bootstrapStart: ContinuousClock.Instant,
        ownership: SessionOwnership,
        installAndroidBuild: Bool
    ) async throws -> BootstrapResult {
        let clock = ContinuousClock()
        // Ensure platform hint is consistent with the selected device.
        guard available.platform == request.platform else {
            throw BootstrapError.platformMismatch(
                requested: request.platform.rawValue,
                actual: available.platform.rawValue
            )
        }

        var tunnelHandle: USBTunnelHandle?
        let deviceID: String
        let port: Int
        do {
            let companionStart = clock.now
            (deviceID, port) = try await ensureCompanion(
                for: available,
                appID: request.appID,
                buildMode: request.buildMode,
                installAndroidBuild: installAndroidBuild,
                requestedPort: request.port
            )
            PerformanceTelemetry.record(
                "companion_startup",
                operation: request.platform.rawValue,
                duration: companionStart.duration(to: clock.now)
            )
            if case let .ios(device) = available, device.isPhysicalDevice {
                tunnelHandle = try await usbTunnel.open(
                    deviceUDID: device.udid,
                    localPort: port,
                    devicePort: port
                )
            }
        } catch {
            if let tunnelHandle {
                try? await usbTunnel.close(tunnelHandle)
            }
            throw error
        }

        // Connect the gRPC client.
        let companion: GRPCCompanionClient
        do {
            companion = try GRPCCompanionClient.makeLive(
                connection: CompanionConnection(host: "127.0.0.1", port: port)
            )
        } catch {
            if let tunnelHandle {
                try? await usbTunnel.close(tunnelHandle)
            }
            throw BootstrapError.connectionFailed(error.localizedDescription)
        }

        let cleanup = makeSessionCleanup(
            companion: companion, tunnelHandle: tunnelHandle, ownership: ownership, device: available
        )

        let platformDriver: any PlatformDriver
        let appArtifactSHA256: String?
        let launchReceipt: AppLaunchReceipt
        do {
            // Unlike a TCP dial, this proves the companion application is serving its API.
            try await waitForCompanionReady(companion)
            platformDriver = await makePlatformDriver(for: available, companion: companion, deviceID: deviceID)
            (appArtifactSHA256, launchReceipt) = try await installAndLaunch(request, driver: platformDriver)
        } catch {
            await cleanup()
            throw error
        }

        // Wait for the first screen to be queryable (best-effort).
        await StartupProgress.report("Waiting for the first app screen")
        let screenReady: Bool
        do {
            screenReady = try await waitForScreenReady(driver: platformDriver)
            try Task.checkCancellation()
        } catch {
            await cleanup()
            throw error
        }
        await StartupProgress.report(screenReady ? "Session ready" : "Session started; semantic readiness unverified")

        PerformanceTelemetry.record(
            "session_bootstrap",
            operation: request.platform.rawValue,
            duration: bootstrapStart.duration(to: clock.now)
        )
        return BootstrapResult(
            driver: platformDriver,
            deviceID: deviceID,
            platform: request.platform,
            appArtifactSHA256: appArtifactSHA256,
            startup: AppStartupState(
                installation: request.freshInstall ? "fresh_installed" : request
                    .buildPath == nil ? "reused" : "installed",
                launch: launchReceipt, semanticReadiness: screenReady ? "queryable" : "unverified"
            ),
            cleanup: cleanup
        )
    }

    /// Builds the platform driver bound to a ready companion + device.
    private func makePlatformDriver(
        for available: AvailableDevice,
        companion: GRPCCompanionClient,
        deviceID: String
    ) async -> any PlatformDriver {
        switch available {
        case .ios:
            await makeIOSDriver(companion: companion, deviceID: deviceID)
        case .android:
            AndroidDriver(
                companion: companion,
                inspectionMode: .productionDefault(),
                serial: deviceID
            )
        case .macos:
            IOSDriver(companion: companion, backend: MacHostBackend(), deviceID: MacHostBackend.deviceID)
        }
    }

    /// Installs the app under test (when a build path was supplied) and launches it, mapping any
    /// failure to the matching `BootstrapError` case.
    func installAndLaunch(
        _ request: SessionBootstrapRequest,
        driver: any PlatformDriver
    ) async throws -> (String?, AppLaunchReceipt) {
        let before = request.buildPath.flatMap { sha256Hex(ofPath: $0) }
        if let buildPath = request.buildPath, !buildPath.isEmpty {
            do {
                if request.freshInstall {
                    await StartupProgress.report("Removing app and local data")
                    if try await driver.listApps().contains(where: { $0.appID == request.appID }) {
                        try await driver.uninstallApp(appID: request.appID)
                    }
                }
                await StartupProgress.report("Installing app under test")
                try await driver.installApp(path: buildPath)
            } catch {
                throw BootstrapError.installFailed(error.localizedDescription)
            }
        }
        let receipt: AppLaunchReceipt
        do {
            await StartupProgress.report("Launching app under test")
            receipt = try await driver.launchAppWithReceipt(
                appID: request.appID,
                arguments: request.arguments,
                environment: request.environment
            )
            // Bind the target app the caller just asked to launch — otherwise `current_app`
            // reports an empty `target_bundle_id` until the caller separately calls
            // `set_target_app`, even though `start_session` already took `app_id`.
            try await driver.setTargetApp(bundleID: request.appID)
        } catch {
            throw BootstrapError.launchFailed(error.localizedDescription)
        }
        let after = request.buildPath.flatMap { sha256Hex(ofPath: $0) }
        return (before == after ? before : nil, receipt)
    }

    func listDevices(platform: Platform?) async throws -> [DeviceInfo] {
        var result: [DeviceInfo] = []

        if platform == nil || platform == .ios {
            let iosBooted = await DeviceSelector(processRunner: processRunner).listBootedDevices()
            result += iosBooted.map { device in
                DeviceInfo(
                    id: device.udid,
                    name: device.name,
                    platform: .ios,
                    osVersion: device.osVersion,
                    state: .booted
                )
            }
        }
        if platform == nil || platform == .android {
            let androidOnline = await AndroidDeviceSelector(processRunner: processRunner).listOnlineDevices()
            result += androidOnline.map { device in
                DeviceInfo(
                    id: device.serial,
                    name: device.name,
                    platform: .android,
                    osVersion: "",
                    state: .booted
                )
            }
        }
        // Listed only when asked for: the Mac is always "booted", and a platform-less listing that
        // included it would invite an agent to drive the user's own desktop by accident.
        if platform == .macos {
            result.append(MacHostBackend.currentDeviceInfo())
        }
        return result
    }

    // MARK: - Private

    /// Ensures the appropriate companion is running for the selected device and
    /// returns the resolved device ID + port the companion is reachable on.
    private func ensureCompanion(
        for device: AvailableDevice,
        appID: String,
        buildMode: SessionBuildMode,
        installAndroidBuild: Bool,
        requestedPort: Int?
    ) async throws -> (deviceID: String, port: Int) {
        switch device {
        case let .ios(booted):
            // One port per simulator: a fixed shared port let only one simulator be recorded at a
            // time and broke whenever anything else held it.
            let port = await IOSCompanionPort.resolve(
                requested: requestedPort,
                serverDefault: serverPort,
                udid: booted.udid,
                isPhysicalDevice: booted.isPhysicalDevice,
                legacyPortOwner: {
                    await companionSimulatorUDID(port: CompanionConfig.defaultPort, processRunner: processRunner)
                }
            )
            var config = CompanionConfig(
                port: port,
                deviceUDID: booted.udid,
                isPhysicalDevice: booted.isPhysicalDevice,
                targetAppID: appID
            )
            config.buildMode = buildMode
            config.bootSimulator = !booted.isPhysicalDevice
            try await iOSCompanionManager.ensureRunning(config: config, force: false)
            return (booted.udid, port)
        case let .android(serial, _):
            // One port per device: concurrent sessions on different emulators must not share one.
            let port: Int = if let requestedPort {
                requestedPort
            } else {
                await androidCompanionManager.companionPort(forSerial: serial)
            }
            var config = AndroidCompanionConfig(port: port, serial: serial)
            config.buildMode = buildMode
            config.buildPrepared = true
            config.installPreparedBuild = installAndroidBuild
            try await androidCompanionManager.ensureRunning(config: config, force: false)
            return (serial, port)
        case .macos:
            var config = CompanionConfig(
                port: requestedPort ?? CompanionConfig.defaultMacPort,
                deviceUDID: MacHostBackend.deviceID,
                targetAppID: appID
            )
            config.buildMode = buildMode
            try await iOSCompanionManager.ensureRunning(config: config, force: false)
            return (MacHostBackend.deviceID, config.port)
        }
    }
}

enum BootstrapError: SessionStartupFailure, CustomStringConvertible {
    case platformMismatch(requested: String, actual: String)
    case connectionFailed(String)
    case installFailed(String)
    case launchFailed(String)

    var startupStage: String {
        switch self {
        case .platformMismatch: "device_selection"
        case .connectionFailed: "companion_readiness"
        case .installFailed: "installation"
        case .launchFailed: "launch"
        }
    }

    var description: String {
        switch self {
        case let .platformMismatch(requested, actual):
            "Requested platform '\(requested)' but selected device is '\(actual)'."
        case let .connectionFailed(reason):
            "Failed to connect to companion gRPC server: \(reason)"
        case let .installFailed(reason):
            "Failed to install app: \(reason)"
        case let .launchFailed(reason):
            "Failed to launch app: \(reason)"
        }
    }
}

// swiftlint:enable multiline_arguments
