import AmooCore
import Foundation
import ProcessRunner

// Split from CompanionCommand.swift to keep that file under the length limit.

func runIOSCompanionWarm(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner()
) async -> CLIResult {
    let config = CompanionConfig(
        companionDir: options.companionDir,
        deviceUDID: options.deviceID,
        readyTimeoutSeconds: options.readyTimeoutSeconds ?? CompanionConfig.readyTimeoutFromEnvironment(),
        targetAppID: options.appID
    )
    let store = CompanionStatusStore(companionDir: config.companionDir)
    let device = config.deviceUDID
    let port = config.port
    store.write(warmRecord(.building, platform: "ios", device: device, port: port, detail: "building bundle"))
    let manager = CompanionManager(processRunner: processRunner)
    do {
        try await manager.install(config: config, force: options.force)
        let reachable = await isTCPPortReachable(host: config.host, port: port, timeoutSeconds: 1.5)
        let phase: CompanionPhase = reachable ? .ready : .built
        let detail = reachable ? "listening on port \(port)" : nil
        store.write(warmRecord(phase, platform: "ios", device: device, port: port, detail: detail))
        print("companion warm: \(phase.rawValue) (ios, port \(port)). "
            + (reachable ? "" : "Run 'amoo companion start' to bring it up."))
        return CLIResult(output: "", exitCode: 0)
    } catch {
        let message = (error as? CompanionError)?.description ?? "Companion warm failed: \(error)"
        store.write(warmRecord(.failed, platform: "ios", device: device, port: port, detail: message))
        return CLIResult(output: message, exitCode: 1)
    }
}

func runAndroidCompanionWarm(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner(),
    currentDirectory: String = FileManager.default.currentDirectoryPath
) async -> CLIResult {
    let companionDir = options.companionDir
        ?? AndroidCompanionConfig.defaultCompanionDir(currentDirectoryPath: currentDirectory)
    let config = AndroidCompanionConfig(
        companionDir: companionDir,
        serial: options.deviceID,
        readyTimeoutSeconds: options.readyTimeoutSeconds ?? AndroidCompanionConfig.readyTimeoutFromEnvironment()
    )
    let store = CompanionStatusStore(companionDir: config.companionDir)
    let device = config.serial ?? ""
    let port = config.port
    store.write(warmRecord(.building, platform: "android", device: device, port: port, detail: "building APKs"))
    let manager = AndroidCompanionManager(processRunner: processRunner)
    do {
        try await manager.install(config: config, force: options.force)
        let reachable = await isTCPPortReachable(host: config.host, port: port, timeoutSeconds: 1.5)
        let phase: CompanionPhase = reachable ? .ready : .built
        let detail = reachable ? "listening on port \(port)" : nil
        store.write(warmRecord(phase, platform: "android", device: device, port: port, detail: detail))
        print("companion warm: \(phase.rawValue) (android, port \(port)). "
            + (reachable ? "" : "Run 'amoo companion start' to bring it up."))
        return CLIResult(output: "", exitCode: 0)
    } catch {
        let message = (error as? AndroidCompanionError)?.description ?? "Android companion warm failed: \(error)"
        store.write(warmRecord(.failed, platform: "android", device: device, port: port, detail: message))
        return CLIResult(output: message, exitCode: 1)
    }
}

func runIOSCompanionStatus(options: CompanionCommandOptions) async -> CLIResult {
    let config = CompanionConfig(
        companionDir: options.companionDir,
        deviceUDID: options.deviceID,
        targetAppID: options.appID
    )
    return await companionStatusResult(
        platform: "ios",
        host: config.host,
        port: config.port,
        store: CompanionStatusStore(companionDir: config.companionDir)
    )
}

func runAndroidCompanionStatus(
    options: CompanionCommandOptions,
    currentDirectory: String = FileManager.default.currentDirectoryPath
) async -> CLIResult {
    let companionDir = options.companionDir
        ?? AndroidCompanionConfig.defaultCompanionDir(currentDirectoryPath: currentDirectory)
    let config = AndroidCompanionConfig(companionDir: companionDir, serial: options.deviceID)
    return await companionStatusResult(
        platform: "android",
        host: config.host,
        port: config.port,
        store: CompanionStatusStore(companionDir: config.companionDir)
    )
}

/// Shared status resolution: a live companion always wins; otherwise report the last `warm` record.
func companionStatusResult(
    platform: String,
    host: String,
    port: Int,
    store: CompanionStatusStore
) async -> CLIResult {
    let reachable = await isTCPPortReachable(host: host, port: port, timeoutSeconds: 1.5)
    let record = store.read()
    let phase: CompanionPhase
    let detail: String?
    if reachable {
        phase = .ready
        detail = "listening on port \(port)"
    } else if let record {
        phase = record.phase == .ready ? .built : record.phase
        detail = record.detail
    } else {
        phase = .notStarted
        detail = nil
    }
    let line = "companion status: \(phase.rawValue)"
        + (detail.map { " — \($0)" } ?? "")
        + " (\(platform), port \(port))"
    return CLIResult(output: line, exitCode: phase.exitCode)
}
