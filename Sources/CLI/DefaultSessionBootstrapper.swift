import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import ProcessRunner
import TestSession

/// Production `SessionBootstrapper`: selects a device, ensures the companion is
/// running on that device, opens a gRPC connection, installs + launches the
/// app under test, and waits for the first stable screen.
struct DefaultSessionBootstrapper: SessionBootstrapper {
    let iOSCompanionManager: any IOSCompanionManaging
    let androidCompanionManager: any AndroidCompanionManaging
    let processRunner: any ProcessRunner
    let usbTunnel: any USBTunneling

    /// How many seconds to wait for `getScreenContext` to succeed after launch
    /// before giving up on screen stabilization.
    let screenStabilizationTimeoutSeconds: Double

    init(
        iOSCompanionManager: any IOSCompanionManaging,
        androidCompanionManager: any AndroidCompanionManaging,
        processRunner: any ProcessRunner = SystemProcessRunner(),
        usbTunnel: any USBTunneling = IProxyTunnel(),
        screenStabilizationTimeoutSeconds: Double = 10
    ) {
        self.iOSCompanionManager = iOSCompanionManager
        self.androidCompanionManager = androidCompanionManager
        self.processRunner = processRunner
        self.usbTunnel = usbTunnel
        self.screenStabilizationTimeoutSeconds = screenStabilizationTimeoutSeconds
    }

    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
        let clock = ContinuousClock()
        let bootstrapStart = clock.now
        let selector = PlatformDeviceSelector(processRunner: processRunner)
        let available = try await selector.selectDevice(hint: request.deviceHint, platform: request.platform)

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
            (deviceID, port) = try await ensureCompanion(for: available, appID: request.appID)
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

        let tunnel = usbTunnel
        let cleanup: @Sendable () async -> Void = { [companion, tunnelHandle, tunnel] in
            await companion.shutdown()
            if let tunnelHandle {
                try? await tunnel.close(tunnelHandle)
            }
        }

        let platformDriver: any PlatformDriver
        do {
            // Unlike a TCP dial, this proves the companion application is serving its API.
            try await waitForCompanionReady(companion)
            platformDriver = await makePlatformDriver(for: available, companion: companion, deviceID: deviceID)
            try await installAndLaunch(request, driver: platformDriver)
        } catch {
            await cleanup()
            throw error
        }

        // Wait for the first screen to be queryable (best-effort).
        await waitForScreenReady(driver: platformDriver)

        PerformanceTelemetry.record(
            "session_bootstrap",
            operation: request.platform.rawValue,
            duration: bootstrapStart.duration(to: clock.now)
        )
        return BootstrapResult(
            driver: platformDriver,
            deviceID: deviceID,
            platform: request.platform,
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
        }
    }

    /// Installs the app under test (when a build path was supplied) and launches it, mapping any
    /// failure to the matching `BootstrapError` case.
    private func installAndLaunch(
        _ request: SessionBootstrapRequest,
        driver: any PlatformDriver
    ) async throws {
        if let buildPath = request.buildPath, !buildPath.isEmpty {
            do {
                try await driver.installApp(path: buildPath)
            } catch {
                throw BootstrapError.installFailed(error.localizedDescription)
            }
        }
        do {
            try await driver.launchApp(
                appID: request.appID,
                arguments: request.arguments,
                environment: request.environment
            )
        } catch {
            throw BootstrapError.launchFailed(error.localizedDescription)
        }
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
        return result
    }

    // MARK: - Private

    /// Ensures the appropriate companion is running for the selected device and
    /// returns the resolved device ID + port the companion is reachable on.
    private func ensureCompanion(
        for device: AvailableDevice,
        appID: String
    ) async throws -> (deviceID: String, port: Int) {
        switch device {
        case let .ios(booted):
            let port = 22087
            let config = CompanionConfig(
                port: port,
                deviceUDID: booted.udid,
                isPhysicalDevice: booted.isPhysicalDevice,
                targetAppID: appID
            )
            try await iOSCompanionManager.ensureRunning(config: config, force: false)
            return (booted.udid, port)
        case let .android(serial, _):
            let port = 22088
            let config = AndroidCompanionConfig(port: port, serial: serial)
            try await androidCompanionManager.ensureRunning(config: config, force: false)
            return (serial, port)
        }
    }

    private func waitForScreenReady(driver: any PlatformDriver) async {
        let deadline = Date().addingTimeInterval(screenStabilizationTimeoutSeconds)
        while Date() < deadline {
            if await (try? driver.getScreenContext()) != nil {
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func waitForCompanionReady(_ companion: any CompanionClient) async throws {
        let deadline = Date().addingTimeInterval(30)
        var lastError: (any Error)?
        while Date() < deadline {
            do {
                let capabilities = try await companion.getCapabilities()
                guard capabilities.contains(where: { $0.key == "protocol.amoo.v1" && $0.supported }) else {
                    throw BootstrapError.connectionFailed(
                        "Companion protocol is incompatible with this Amoo CLI. Update/reinstall the companion "
                            + "with `amoo companion install --platform ios` (or android), then restart the session."
                    )
                }
                return
            } catch let error as BootstrapError {
                throw error
            } catch {
                if error.localizedDescription.localizedCaseInsensitiveContains("rpc isn't implemented")
                    || error.localizedDescription.localizedCaseInsensitiveContains("unimplemented") {
                    throw BootstrapError.connectionFailed(
                        "The running companion does not implement the RPCs required by this Amoo CLI. "
                            + "Update/reinstall it with `amoo companion install --platform ios` (or android)."
                    )
                }
                lastError = error
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        throw BootstrapError.connectionFailed(
            lastError?.localizedDescription ?? "Companion gRPC readiness timed out."
        )
    }
}

enum BootstrapError: Error, CustomStringConvertible {
    case platformMismatch(requested: String, actual: String)
    case connectionFailed(String)
    case installFailed(String)
    case launchFailed(String)

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
