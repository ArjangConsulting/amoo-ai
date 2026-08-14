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
    let iOSCompanionManager: CompanionManager
    let androidCompanionManager: AndroidCompanionManager
    let processRunner: any ProcessRunner

    /// How many seconds to wait for `getScreenContext` to succeed after launch
    /// before giving up on screen stabilization.
    let screenStabilizationTimeoutSeconds: Double

    init(
        iOSCompanionManager: CompanionManager,
        androidCompanionManager: AndroidCompanionManager,
        processRunner: any ProcessRunner = SystemProcessRunner(),
        screenStabilizationTimeoutSeconds: Double = 10
    ) {
        self.iOSCompanionManager = iOSCompanionManager
        self.androidCompanionManager = androidCompanionManager
        self.processRunner = processRunner
        self.screenStabilizationTimeoutSeconds = screenStabilizationTimeoutSeconds
    }

    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
        let appID = request.appID
        let platform = request.platform
        let deviceHint = request.deviceHint
        let buildPath = request.buildPath
        let arguments = request.arguments
        let environment = request.environment

        let selector = PlatformDeviceSelector(processRunner: processRunner)
        let available = try await selector.selectDevice(hint: deviceHint, platform: platform)

        // Ensure platform hint is consistent with the selected device.
        guard available.platform == platform else {
            throw BootstrapError.platformMismatch(
                requested: platform.rawValue,
                actual: available.platform.rawValue
            )
        }

        let (deviceID, port) = try await ensureCompanion(for: available, appID: appID)

        // Connect the gRPC client.
        let companion: GRPCCompanionClient
        do {
            companion = try GRPCCompanionClient.makeLive(
                connection: CompanionConnection(host: "127.0.0.1", port: port)
            )
        } catch {
            throw BootstrapError.connectionFailed(error.localizedDescription)
        }

        // Build the platform driver bound to that companion + device.
        let platformDriver: any PlatformDriver = switch available {
        case .ios:
            await makeIOSDriver(companion: companion, deviceID: deviceID)
        case .android:
            AndroidDriver(companion: companion, serial: deviceID)
        }

        // Install the app under test if a build path was supplied.
        if let buildPath, !buildPath.isEmpty {
            do {
                try await platformDriver.installApp(path: buildPath)
            } catch {
                await companion.shutdown()
                throw BootstrapError.installFailed(error.localizedDescription)
            }
        }

        // Launch the app.
        do {
            try await platformDriver.launchApp(
                appID: appID,
                arguments: arguments,
                environment: environment
            )
        } catch {
            await companion.shutdown()
            throw BootstrapError.launchFailed(error.localizedDescription)
        }

        // Wait for the first screen to be queryable (best-effort).
        await waitForScreenReady(driver: platformDriver)

        let cleanup: @Sendable () async -> Void = { [companion] in
            await companion.shutdown()
        }

        return BootstrapResult(
            driver: platformDriver,
            deviceID: deviceID,
            platform: platform,
            cleanup: cleanup
        )
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
                targetAppID: appID
            )
            try await iOSCompanionManager.ensureRunning(config: config)
            return (booted.udid, port)
        case let .android(serial, _):
            let port = 22088
            let config = AndroidCompanionConfig(port: port, serial: serial)
            try await androidCompanionManager.ensureRunning(config: config)
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
