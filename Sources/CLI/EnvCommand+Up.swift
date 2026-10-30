import AdbKit
import AmooCore
import Foundation
import MobileCore
import MobileDevices
import ProcessRunner
import SwiftyShell
import XcrunKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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

/// Injectable lifecycle boundaries; init and env share the same runtime orchestration.
struct EnvUpDependencies {
    var health = DeviceRuntimeHealth()
    var resolve: (EnvUpOptions, DeviceRuntimeStore) async throws -> EnvDeviceReport = { options, store in
        switch options.platform {
        case .android: try await resolveEnvAndroidDevice(options, store: store)
        case .ios: try await resolveEnvIOSDevice(options, store: store)
        }
    }

    var start: (EnvUpOptions, DeviceRuntime, DeviceRuntimeStore) async throws -> DeviceRuntime = {
        try await startRuntimeCompanion($0, runtime: $1, store: $2)
    }

    var prepare: (EnvUpOptions, DeviceRuntime, inout EnvAppReport?) async throws -> Void = {
        try await prepareEnvApp($0, runtime: $1, app: &$2)
    }
}

func runEnvUp(
    _ options: EnvUpOptions,
    store: DeviceRuntimeStore = DeviceRuntimeStore(),
    dependencies: EnvUpDependencies = EnvUpDependencies()
) async -> CLIResult {
    var report = EnvUpReport(ok: false, platform: options.platform.rawValue)
    let finish: (Int32) -> CLIResult = { code in
        CLIResult(output: options.json ? renderJSON(report) : report.humanSummary, exitCode: code)
    }
    let store = options.ttlMinutes.map {
        DeviceRuntimeStore(
            directory: store.directory,
            legacyDirectory: store.legacyDirectory,
            ttl: Double($0) * 60,
            reaper: store.reaper
        )
    } ?? store
    // `env up` takes devices, so it clears what expired runtimes left running; listing never does.
    if let reused = await reuseDeviceRuntime(options, store: store, dependencies: dependencies) {
        return CLIResult(output: options.json ? renderJSON(reused) : reused.humanSummary, exitCode: reused.ok ? 0 : 1)
    }
    store.reapExpired()

    let device: EnvDeviceReport
    do {
        device = try await dependencies.resolve(options, store)
    } catch {
        report.error = "\(error)"
        return finish(1)
    }
    report.device = device
    report.prepareApp(options)

    var runtime: DeviceRuntime
    do {
        runtime = try store.start(
            platform: options.platform,
            deviceID: device.id,
            deviceName: device.avd ?? device.name,
            owner: options.owner ?? ProcessInfo.processInfo.environment["AMOO_RUNTIME_OWNER"]
        )
    } catch {
        report.error = "\(error)"
        return finish(3)
    }
    runtime.bootedByRuntime = device.bootedByEnv
    runtime.appID = options.appID
    report.runtimeID = runtime.id

    do {
        runtime = try await dependencies.start(options, runtime, store)
        report.port = runtime.port
        report.companionPID = runtime.companionPID
        report.log = store.logURL(runtimeID: runtime.id).path
        try await dependencies.prepare(options, runtime, &report.app)
    } catch {
        report.error = "\(error)"
        report.log = store.logURL(runtimeID: runtime.id).path
        let storedRuntime = store.runtime(id: runtime.id) ?? runtime
        report.port = storedRuntime.port
        report.companionPID = storedRuntime.companionPID
        if stopRuntimeCompanion(storedRuntime) {
            store.stop(runtime)
        }
        return finish(1)
    }
    report.ok = true
    report.state = .running
    return finish(0)
}

// MARK: - Device resolution

private func resolveEnvAndroidDevice(
    _ options: EnvUpOptions,
    store: DeviceRuntimeStore
) async throws -> EnvDeviceReport {
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
            guard !options.coldBoot else {
                throw EnvError
                    .noDevice("AVD '\(avd)' is already running. Verify device_shutdown before using --cold-boot.")
            }
            return EnvDeviceReport(id: serial, name: nil, os: nil, avd: avd, bootedByEnv: false)
        case .bootAVD:
            let booted = try await selector.bootVirtualDevice(name: avd, coldBoot: options.coldBoot)
            return EnvDeviceReport(id: booted.id, name: nil, os: nil, avd: avd, bootedByEnv: true)
        case .running, .unmatched:
            throw await EnvError.noDevice("No AVD named '\(avd)'. Installed: "
                + (selector.listAvailableVirtualDevices().map(\.name).joined(separator: ", ")))
        }
    }
    // Nothing named: the first running emulator nobody has controlled.
    for device in online where device.serial.hasPrefix("emulator-") && store.runtime(forDevice: device.serial) == nil {
        let avd = await selector.runningAVDName(serial: device.serial)
        return EnvDeviceReport(id: device.serial, name: nil, os: nil, avd: avd, bootedByEnv: false)
    }
    throw await EnvError.noDevice("No available Android emulator is running. Pass --avd <name> to boot one: "
        + (selector.listAvailableVirtualDevices().map(\.name).joined(separator: ", ")))
}

private func resolveEnvIOSDevice(_ options: EnvUpOptions, store: DeviceRuntimeStore) async throws -> EnvDeviceReport {
    let selector = DeviceSelector()
    let available = await selector.listAvailableSimulators()
    let booted = await Set(selector.listBootedDevices().filter { !$0.isPhysicalDevice }.map(\.udid))

    let simulator: IOSSimulatorDevice
    if let udid = options.deviceID {
        if let existing = store.runtime(forDevice: udid) {
            throw DeviceAccessError.controlledByOther(existing)
        }
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
            isControlled: { store.runtime(forDevice: $0) != nil }
        ) else {
            throw EnvError.noDevice("No available simulator matches runtime=\(options.runtime ?? "any")"
                + " model=\(options.model ?? "any"). `xcrun simctl list devices available` shows the options.")
        }
        simulator = picked
    }

    let needsBoot = !booted.contains(simulator.udid)
    if needsBoot {
        try await bootSimulator(udid: simulator.udid, readyTimeoutSeconds: options.readyTimeoutSeconds)
    }
    return EnvDeviceReport(
        id: simulator.udid,
        name: simulator.name,
        os: "iOS \(simulator.osVersion)",
        avd: nil,
        bootedByEnv: needsBoot
    )
}

/// What `simctl boot` said, reduced to what `env up` must act on: nil means carry on to the
/// `bootstatus` wait, a message means fail now with simctl's own words.
func simulatorBootFailure(exitCode: Int32?, stderr: String?) -> String? {
    guard let exitCode, exitCode != 0 else { return nil }
    let text = (stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // Racing another booter: "Unable to boot device in current state: Booted" is not a failure.
    if text.contains("current state: Booted") || text.contains("current state: Booting") {
        return nil
    }
    return text.isEmpty ? "simctl boot exited \(exitCode)" : text
}

private func bootSimulator(udid: String, readyTimeoutSeconds: Int?) async throws {
    let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner()))
    let waitSeconds = readyTimeoutSeconds ?? 300
    do {
        try await SimulatorManager(shell: context).boot(udid, timeout: .seconds(waitSeconds))
    } catch let MobileKitError.commandFailed(command, exitCode, output)
        where command.last == udid && command.contains("boot") {
        // A missing runtime image ("The iOS 27.0 simulator runtime is not available") can never boot;
        // say so now rather than waiting on `bootstatus` and reporting a bogus timeout.
        let failure = simulatorBootFailure(exitCode: exitCode, stderr: output) ?? "simctl boot exited \(exitCode)"
        throw EnvError.noDevice("Simulator \(udid) could not boot: \(failure)")
    } catch let MobileKitError.commandFailed(_, _, output) {
        throw EnvError
            .noDevice(
                "Simulator \(udid) did not finish booting: \(output.isEmpty ? "simctl bootstatus failed" : output)"
            )
    } catch MobileKitError.timedOut {
        throw EnvError
            .noDevice("Simulator \(udid) did not finish booting: no `simctl bootstatus` result within \(waitSeconds)s")
    }
}

// MARK: - Companion process

/// Starts `amoo companion start` detached (own session, survives this process), records it in
/// the runtime, and waits until the companion answers gRPC.
private func startRuntimeCompanion(
    _ options: EnvUpOptions,
    runtime: DeviceRuntime,
    store: DeviceRuntimeStore
) async throws -> DeviceRuntime {
    var runtime = runtime
    let reservedPorts = Set(store.all().compactMap(\.port))
    var chosenPort = options.port
    if chosenPort == nil {
        chosenPort = await pickFreeCompanionPort(reservedPorts: reservedPorts) {
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
        "--device", runtime.deviceID,
        "--port", String(port),
        "--ready-timeout", String(readyTimeout)
    ]
    if let appID = options.appID {
        arguments += ["--app", appID]
    }
    let log = store.logURL(runtimeID: runtime.id).path
    FileManager.default.createFile(atPath: log, contents: nil)
    let pid = try await DetachedProcess.spawn(arguments, logPath: log, environment: ["AMOO_RUNTIME_ID": runtime.id])

    runtime.port = port
    runtime.companionPID = pid
    do {
        runtime = try store.refresh(runtime)
    } catch {
        stopProcess(pid: pid)
        throw error
    }

    // The process builds (iOS: minutes on a cold cache) and then waits `readyTimeout` itself; give
    // it that plus build slack, and stop early if it dies.
    let deadline = Date().addingTimeInterval(Double(readyTimeout + 600))
    while Date() < deadline {
        if await isCompanionReady(host: "127.0.0.1", port: port) {
            try await verifyCompanionOwner(platform: options.platform, port: port, deviceID: runtime.deviceID)
            runtime.state = .running
            return try store.refresh(runtime)
        }
        guard kill(pid, 0) == 0 else {
            throw EnvError.companionFailed("The companion process exited before becoming ready:\n" + logTail(log))
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

/// SIGTERM the process's process group (it tears its runner down), SIGKILL if it lingers.
func stopProcess(pid: Int32?, graceSeconds: Double = 20) {
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

// MARK: - Orphaned processes

/// Command line of `pid` (`ps -o command=`), nil when it is gone.
func processCommandLine(pid: Int32) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", String(pid), "-o", "command="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text : nil
}

/// Whether `command` is an `amoo companion start` process for `deviceID`. Guards against PID reuse:
/// a runtime can outlive its process by an hour, and the pid may by then belong to anything.
func isCompanionProcessCommand(_ command: String, deviceID: String) -> Bool {
    let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
    // `ps` does not quote, so an executable path containing spaces splits into several words;
    // the word before `companion` still ends with the executable's name.
    guard let start = words.firstIndex(of: "companion"), start > 0,
          URL(fileURLWithPath: words[start - 1]).lastPathComponent == "amoo",
          words.dropFirst(start + 1).first == "start",
          let device = words.firstIndex(of: "--device"), words.indices.contains(device + 1)
    else { return false }
    return words[device + 1] == deviceID
}

/// `amoo companion start … --device <id>` processes in `ps -axo pid=,args=` output.
func parseCompanionProcessPIDs(_ psOutput: String, deviceID: String) -> [Int32] {
    psOutput.split(whereSeparator: \.isNewline).compactMap { line in
        let trimmed = line.drop(while: { $0 == " " })
        guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { return nil }
        return isCompanionProcessCommand(String(trimmed[space...]), deviceID: deviceID) ? pid : nil
    }
}

func orphanedCompanionProcesses(deviceID: String) async -> [Int32] {
    guard let ps = try? await SystemProcessRunner().run(["/bin/ps", "-axo", "pid=,args="]) else { return [] }
    return parseCompanionProcessPIDs(ps.stdout, deviceID: deviceID).filter { $0 != getpid() }
}

/// Packages the Android companion runs as; `am instrument` alone only force-stops the `.test` one.
let androidCompanionPackages = ["com.amoo.companion.test", "com.amoo.companion"]

@discardableResult
func forceStopAndroidCompanion(serial: String) async -> Bool {
    let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner()))
    var stopped = true
    for package in androidCompanionPackages {
        do { try await AndroidDeviceManager(shell: context).terminate(package: package, on: serial) } catch {
            stopped = false
        }
    }
    return stopped
}

/// Default `DeviceRuntimeStore.reaper`: stop the process of an expired runtime, and for Android
/// force-stop the on-device runner too (killing the host side does not reliably end it).
@Sendable
func reapExpiredRuntime(_ runtime: DeviceRuntime) -> Bool {
    guard stopRuntimeCompanion(runtime) else { return false }
    if runtime.platform == .android, runtime.deviceID.hasPrefix("emulator-") {
        return reapAndroidRemainder(runtime)
    }
    return true
}

private func reapAndroidRemainder(_ runtime: DeviceRuntime) -> Bool {
    var stopped = true
    for package in androidCompanionPackages {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let command = Adb().serial(runtime.deviceID).amForceStop(package: package).command()
        process.arguments = [command.executableName] + command.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
            stopped = stopped && process.terminationStatus == 0
        } else {
            stopped = false
        }
    }
    return stopped
}

func logTail(_ path: String, characters: Int = 2000) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "(no log at \(path))" }
    return String(text.suffix(characters))
}

// MARK: - App

private func prepareEnvApp(_ options: EnvUpOptions, runtime: DeviceRuntime, app: inout EnvAppReport?) async throws {
    guard options.appPath != nil || options.appID != nil, let port = runtime.port else { return }

    func run(_ tool: String, _ arguments: [String: String]) async throws {
        let result = await runDeviceCommand(options: DeviceCommandOptions(
            platform: options.platform,
            port: port,
            deviceID: runtime.deviceID,
            tool: tool,
            arguments: arguments,
            runtimeID: runtime.id
        ))
        guard result.exitCode == 0 else { throw EnvError.appFailed("\(tool) failed: \(result.output)") }
    }

    if let path = options.appPath {
        guard FileManager.default.fileExists(atPath: path) else { throw EnvError.appFailed("No app at \(path).") }
        try await run("device_install_app", ["path": path])
        app?.installed = true
    }
    if let appID = options.appID {
        app?.installed = await isAppInstalled(platform: options.platform, deviceID: runtime.deviceID, appID: appID)
        guard app?.installed == true
        else { throw EnvError.appFailed("\(appID) is not installed on \(runtime.deviceID).") }
        if options.launch {
            try await run("device_launch_app", ["app_id": appID])
            app?.launched = true
        }
    } else {
        app?.installed = options.appPath != nil
    }
}

/// Read-only install check, independent of the companion.
private func isAppInstalled(platform: Platform, deviceID: String, appID: String) async -> Bool {
    let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner()))
    switch platform {
    case .android:
        return await (try? Adb(context: context).serial(deviceID).pmPath(package: appID).run()) != nil
    case .ios:
        return await (try? Simctl(context: context).getAppContainer(deviceID, bundleIdentifier: appID).run()) != nil
    }
}
