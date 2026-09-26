import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Reports

struct EnvDeviceReport: Encodable, Equatable {
    var id: String
    var name: String?
    var os: String?
    var avd: String?
    var bootedByEnv: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, os, avd
        case bootedByEnv = "booted_by_env"
    }
}

struct EnvAppReport: Encodable, Equatable {
    var id: String?
    var path: String?
    var sha256: String?
    var installed: Bool
    var launched: Bool
}

struct EnvUpReport: Encodable {
    var ok: Bool
    var lease: String?
    var platform: String
    var device: EnvDeviceReport?
    var port: Int?
    var holderPID: Int32?
    var app: EnvAppReport?
    var log: String?
    var amooVersion = AmooBuildInfo.current.version
    var amooCommit = AmooBuildInfo.current.sourceCommit
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, lease, platform, device, port, app, log, error
        case holderPID = "holder_pid"
        case amooVersion = "amoo_version"
        case amooCommit = "amoo_commit"
    }

    var humanSummary: String {
        guard ok, let lease, let device, let port else {
            return "env up failed: \(error ?? "unknown error")" + (log.map { "\nLog: \($0)" } ?? "")
        }
        var lines = [
            "Leased \(device.name ?? device.id) (\(device.id)) as \(lease).",
            "Companion on port \(port) (holder pid \(holderPID.map(String.init) ?? "?"), log \(log ?? "-")).",
            "Use: amoo device --platform \(platform) --device \(device.id) --port \(port) --lease \(lease) <tool>"
        ]
        if let app {
            lines.append("App \(app.id ?? app.path ?? "?"): installed=\(app.installed) launched=\(app.launched)")
        }
        return lines.joined(separator: "\n")
    }
}

enum EnvError: Error, CustomStringConvertible {
    case physicalDevice(String)
    case noDevice(String)
    case companionFailed(String)
    case appFailed(String)

    var description: String {
        switch self {
        case let .physicalDevice(id):
            "\(id) is a physical device. `amoo env` only uses simulators and emulators."
        case let .noDevice(message), let .companionFailed(message), let .appFailed(message):
            message
        }
    }
}

// MARK: - env up

func runEnvUp(_ options: EnvUpOptions, store: DeviceLeaseStore = DeviceLeaseStore()) async -> CLIResult {
    var report = EnvUpReport(ok: false, platform: options.platform.rawValue)
    let finish: (Int32) -> CLIResult = { code in
        CLIResult(output: options.json ? renderJSON(report) : report.humanSummary, exitCode: code)
    }
    let store = options.ttlMinutes.map { DeviceLeaseStore(directory: store.directory, ttl: Double($0) * 60) } ?? store

    let device: EnvDeviceReport
    do {
        device = switch options.platform {
        case .android: try await resolveEnvAndroidDevice(options, store: store)
        case .ios: try await resolveEnvIOSDevice(options, store: store)
        }
    } catch {
        report.error = "\(error)"
        return finish(1)
    }
    report.device = device

    var lease: DeviceLease
    do {
        lease = try store.acquire(
            platform: options.platform,
            deviceID: device.id,
            deviceName: device.avd ?? device.name,
            owner: options.owner ?? ProcessInfo.processInfo.environment["AMOO_LEASE_OWNER"]
        )
    } catch {
        report.error = "\(error)"
        return finish(3)
    }
    lease.bootedByLease = device.bootedByEnv
    lease.appID = options.appID
    report.lease = lease.id

    do {
        lease = try await startLeasedCompanion(options, lease: lease, store: store)
        report.port = lease.port
        report.holderPID = lease.holderPID
        report.log = store.logURL(leaseID: lease.id).path
        report.app = try await prepareEnvApp(options, lease: lease)
    } catch {
        report.error = "\(error)"
        report.log = store.logURL(leaseID: lease.id).path
        stopHolder(pid: lease.holderPID)
        store.release(lease)
        return finish(1)
    }
    report.ok = true
    return finish(0)
}

// MARK: - Device resolution

private func resolveEnvAndroidDevice(_ options: EnvUpOptions, store: DeviceLeaseStore) async throws -> EnvDeviceReport {
    let selector = AndroidDeviceSelector()
    let online = await selector.listOnlineDevices()
    if let serial = options.deviceID {
        guard serial.hasPrefix("emulator-") else { throw EnvError.physicalDevice(serial) }
        guard online.contains(where: { $0.serial == serial }) else {
            throw EnvError.noDevice("Emulator \(serial) is not online (`adb devices`).")
        }
        return await EnvDeviceReport(
            id: serial,
            name: nil,
            os: nil,
            avd: selector.runningAVDName(serial: serial),
            bootedByEnv: false
        )
    }
    if let avd = options.avd {
        switch await selector.resolve(hint: avd) {
        case let .running(serial, _) where serial.hasPrefix("emulator-"):
            return EnvDeviceReport(id: serial, name: nil, os: nil, avd: avd, bootedByEnv: false)
        case .bootAVD:
            let booted = try await selector.bootVirtualDevice(name: avd)
            return EnvDeviceReport(id: booted.id, name: nil, os: nil, avd: avd, bootedByEnv: true)
        case .running, .unmatched:
            throw await EnvError.noDevice("No AVD named '\(avd)'. Installed: "
                + (selector.listAvailableVirtualDevices().map(\.name).joined(separator: ", ")))
        }
    }
    // Nothing named: the first running emulator nobody has leased.
    for device in online where device.serial.hasPrefix("emulator-") && store.lease(forDevice: device.serial) == nil {
        let avd = await selector.runningAVDName(serial: device.serial)
        return EnvDeviceReport(id: device.serial, name: nil, os: nil, avd: avd, bootedByEnv: false)
    }
    throw await EnvError.noDevice("No unleased Android emulator is running. Pass --avd <name> to boot one: "
        + (selector.listAvailableVirtualDevices().map(\.name).joined(separator: ", ")))
}

private func resolveEnvIOSDevice(_ options: EnvUpOptions, store: DeviceLeaseStore) async throws -> EnvDeviceReport {
    let selector = DeviceSelector()
    let available = await selector.listAvailableSimulators()
    let booted = await Set(selector.listBootedDevices().filter { !$0.isPhysicalDevice }.map(\.udid))

    let simulator: IOSSimulatorDevice
    if let udid = options.deviceID {
        guard let match = available.first(where: { $0.udid == udid }) else {
            if await selector.isPhysicalDevice(deviceID: udid) {
                throw EnvError.physicalDevice(udid)
            }
            throw EnvError.noDevice("No simulator with UDID \(udid).")
        }
        simulator = match
    } else {
        guard let picked = pickIOSSimulator(
            runtime: options.runtime,
            model: options.model,
            available: available,
            bootedUDIDs: booted,
            isLeased: { store.lease(forDevice: $0) != nil }
        ) else {
            throw EnvError.noDevice("No unleased simulator matches runtime=\(options.runtime ?? "any")"
                + " model=\(options.model ?? "any"). `xcrun simctl list devices available` shows the options.")
        }
        simulator = picked
    }

    let needsBoot = !booted.contains(simulator.udid)
    if needsBoot {
        try await bootSimulator(udid: simulator.udid)
    }
    return EnvDeviceReport(
        id: simulator.udid,
        name: simulator.name,
        os: "iOS \(simulator.osVersion)",
        avd: nil,
        bootedByEnv: needsBoot
    )
}

private func bootSimulator(udid: String) async throws {
    let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner()))
    // `boot` fails with "Unable to boot device in current state: Booted" when it raced us; the
    // `bootstatus -b` wait below is the real check.
    _ = try? await Command("xcrun").args(["simctl", "boot", udid]).timeout(60).run(in: context)
    let status = try? await Command("xcrun").args(["simctl", "bootstatus", udid, "-b"]).timeout(300).run(in: context)
    guard status?.exitCode == 0 else {
        throw EnvError.noDevice("Simulator \(udid) did not finish booting: \(status?.stderr ?? "timed out")")
    }
}

// MARK: - Companion holder

/// Starts `amoo companion start` detached (own session, survives this process), records it in
/// the lease, and waits until the companion answers gRPC.
private func startLeasedCompanion(
    _ options: EnvUpOptions,
    lease: DeviceLease,
    store: DeviceLeaseStore
) async throws -> DeviceLease {
    var lease = lease
    let leasedPorts = Set(store.all().compactMap(\.port))
    var chosenPort = options.port
    if chosenPort == nil {
        chosenPort = await pickFreeCompanionPort(leasedPorts: leasedPorts) {
            await isTCPPortReachable(host: "127.0.0.1", port: $0, timeoutSeconds: 0.3)
        }
    }
    guard let port = chosenPort else {
        throw EnvError.companionFailed("No free companion port in 22093-22199.")
    }
    guard let executable = AmooBuildInfo.current.executablePath else {
        throw EnvError.companionFailed("Cannot locate the amoo executable to start the companion.")
    }

    let readyTimeout = options.readyTimeoutSeconds
        ??
        (options.platform == .ios ? CompanionConfig.defaultReadyTimeoutSeconds : AndroidCompanionConfig
            .defaultReadyTimeoutSeconds)
    var arguments = [
        executable, "companion", "start",
        "--platform", options.platform.rawValue,
        "--device", lease.deviceID,
        "--port", String(port),
        "--ready-timeout", String(readyTimeout)
    ]
    if let appID = options.appID {
        arguments += ["--app", appID]
    }
    let log = store.logURL(leaseID: lease.id).path
    FileManager.default.createFile(atPath: log, contents: nil)
    let pid = try DetachedProcess.spawn(arguments, logPath: log, environment: ["AMOO_LEASE": lease.id])

    lease.port = port
    lease.holderPID = pid
    lease = try store.update(lease)

    // The holder builds (iOS: minutes on a cold cache) and then waits `readyTimeout` itself; give
    // it that plus build slack, and stop early if it dies.
    let deadline = Date().addingTimeInterval(Double(readyTimeout + 600))
    while Date() < deadline {
        if await isCompanionReady(host: "127.0.0.1", port: port) {
            try await verifyCompanionOwner(platform: options.platform, port: port, deviceID: lease.deviceID)
            return try store.update(lease)
        }
        guard kill(pid, 0) == 0 else {
            throw EnvError.companionFailed("The companion holder exited before becoming ready:\n" + logTail(log))
        }
        try await Task.sleep(for: .seconds(2))
    }
    throw EnvError.companionFailed("The companion did not become ready on port \(port):\n" + logTail(log))
}

/// iOS only: the listener on `port` must be the runner inside *this* simulator.
private func verifyCompanionOwner(platform: Platform, port: Int, deviceID: String) async throws {
    guard platform == .ios,
          let owner = await companionSimulatorUDID(port: port, processRunner: SystemProcessRunner())
    else { return }
    guard owner.caseInsensitiveCompare(deviceID) == .orderedSame else {
        throw EnvError.companionFailed("Port \(port) is served by simulator \(owner), not \(deviceID).")
    }
}

/// SIGTERM the holder's process group (it tears its runner down), SIGKILL if it lingers.
func stopHolder(pid: Int32?, graceSeconds: Double = 20) {
    guard let pid, pid > 0, kill(pid, 0) == 0 else { return }
    kill(-pid, SIGTERM)
    let deadline = Date().addingTimeInterval(graceSeconds)
    while Date() < deadline, kill(pid, 0) == 0 {
        Thread.sleep(forTimeInterval: 0.25)
    }
    if kill(pid, 0) == 0 {
        kill(-pid, SIGKILL)
    }
}

func logTail(_ path: String, characters: Int = 2000) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "(no log at \(path))" }
    return String(text.suffix(characters))
}

// MARK: - App

private func prepareEnvApp(_ options: EnvUpOptions, lease: DeviceLease) async throws -> EnvAppReport? {
    guard options.appPath != nil || options.appID != nil else { return nil }
    guard let port = lease.port else { return nil }
    var app = EnvAppReport(id: options.appID, path: options.appPath, sha256: nil, installed: false, launched: false)

    func run(_ tool: String, _ arguments: [String: String]) async throws {
        let result = await runDeviceCommand(options: DeviceCommandOptions(
            platform: options.platform,
            port: port,
            deviceID: lease.deviceID,
            tool: tool,
            arguments: arguments,
            lease: lease.id
        ))
        guard result.exitCode == 0 else { throw EnvError.appFailed("\(tool) failed: \(result.output)") }
    }

    if let path = options.appPath {
        guard FileManager.default.fileExists(atPath: path) else { throw EnvError.appFailed("No app at \(path).") }
        app.sha256 = sha256Hex(ofPath: path)
        try await run("device_install_app", ["path": path])
    }
    if let appID = options.appID {
        app.installed = await isAppInstalled(platform: options.platform, deviceID: lease.deviceID, appID: appID)
        guard app.installed else { throw EnvError.appFailed("\(appID) is not installed on \(lease.deviceID).") }
        if options.launch {
            try await run("device_launch_app", ["app_id": appID])
            app.launched = true
        }
    } else {
        app.installed = options.appPath != nil
    }
    return app
}

/// Read-only install check, independent of the companion.
private func isAppInstalled(platform: Platform, deviceID: String, appID: String) async -> Bool {
    let arguments = switch platform {
    case .android: ["adb", "-s", deviceID, "shell", "pm", "path", appID]
    case .ios: ["xcrun", "simctl", "get_app_container", deviceID, appID]
    }
    return await (try? SystemProcessRunner().run(arguments))?.exitCode == 0
}
