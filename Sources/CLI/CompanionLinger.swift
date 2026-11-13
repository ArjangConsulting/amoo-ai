import AmooCore
import AmooLogging
import Foundation
import ProcessRunner
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A companion its server left running on purpose when it exited.
///
/// Starting a companion is the slow part of a session, and every delegated run is its own
/// `amoo mcp serve`. Stopping the companion with the server made each run pay that start again.
/// A server now leaves its simulator and emulator companions up for the idle window and records
/// them here; a detached `amoo companion reap` stops one whose window ran out with nobody on it.
struct CompanionLinger: Codable, Equatable, Sendable {
    /// Identifies this hand-off. A later owner replaces or removes the record, which stands the reaper down.
    var token: String
    var platform: String
    var deviceID: String
    var port: Int
    var expiresAt: Date
}

struct CompanionLingerStore: Sendable {
    let directory: URL

    init(directory: URL = CompanionRegistry().directory) {
        self.directory = directory
    }

    private func fileURL(platform: String, port: Int) -> URL {
        directory.appending(path: "linger-\(platform)-\(port).record")
    }

    func write(_ linger: CompanionLinger) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(linger) else { return }
        try? data.write(to: fileURL(platform: linger.platform, port: linger.port), options: .atomic)
    }

    func read(platform: String, port: Int) -> CompanionLinger? {
        guard let data = try? Data(contentsOf: fileURL(platform: platform, port: port)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CompanionLinger.self, from: data)
    }

    /// Takes the companion over from whoever left it: its reaper finds no record and stops nothing.
    func claim(platform: String, port: Int) {
        try? FileManager.default.removeItem(at: fileURL(platform: platform, port: port))
    }

    /// Removes the record only while `token` still owns it.
    func remove(_ linger: CompanionLinger) -> Bool {
        guard read(platform: linger.platform, port: linger.port)?.token == linger.token else { return false }
        claim(platform: linger.platform, port: linger.port)
        return true
    }
}

/// How a hand-off reaches the outside world, so tests can observe it without spawning anything.
struct CompanionLingerHooks: Sendable {
    var executablePath: @Sendable () -> String?
    var spawn: @Sendable (_ arguments: [String]) async throws -> Void
    var store: CompanionLingerStore

    static let live = Self(
        executablePath: { AmooBuildInfo.current.executablePath },
        spawn: { arguments in _ = try await DetachedProcess.spawn(arguments) },
        store: CompanionLingerStore()
    )
}

private let lingerLogger = AmooLogger.forType(CompanionLingerStore.self)

/// Records the hand-off and starts its reaper. Returns false when the reaper could not be started,
/// in which case the caller must stop the companion itself rather than leave it with no end.
func leaveCompanionRunning(
    platform: String,
    deviceID: String,
    port: Int,
    seconds: Double,
    hooks: CompanionLingerHooks = .live
) async -> Bool {
    guard seconds > 0, let executable = hooks.executablePath() else { return false }
    let linger = CompanionLinger(
        token: UUID().uuidString,
        platform: platform,
        deviceID: deviceID,
        port: port,
        expiresAt: Date().addingTimeInterval(seconds)
    )
    hooks.store.write(linger)
    do {
        try await hooks.spawn([
            executable, "companion", "reap", "--platform", platform, "--device", deviceID,
            "--port", String(port), "--token", linger.token, "--after", String(Int(seconds.rounded(.up)))
        ])
        lingerLogger.info("Left companion running for the next session", context: "platform=\(platform) port=\(port)")
        return true
    } catch {
        lingerLogger.error("Could not start the companion reaper", error: error, context: "port=\(port)")
        _ = hooks.store.remove(linger)
        return false
    }
}

// MARK: - `amoo companion reap`

struct CompanionReapOptions: Equatable {
    var platform: Platform
    var deviceID: String
    var port: Int
    var token: String
    var afterSeconds: Double

    static func parse(_ arguments: [String]) -> Self? {
        var values: [String: String] = [:]
        var index = 0
        while index + 1 < arguments.count {
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard arguments.count.isMultiple(of: 2),
              let platform = values["--platform"].flatMap(Platform.init(rawValue:)),
              let deviceID = values["--device"], let port = values["--port"].flatMap(Int.init),
              let token = values["--token"], let after = values["--after"].flatMap(Double.init), after >= 0
        else { return nil }
        return Self(platform: platform, deviceID: deviceID, port: port, token: token, afterSeconds: after)
    }
}

/// What the reaper decided, for its exit message and for tests.
enum CompanionReapOutcome: Equatable {
    /// Another owner replaced or removed the record.
    case superseded
    /// A live session holds the device; its own server ends the companion later.
    case inUse
    case stopped
}

/// Waits out the idle window, then stops the companion unless someone took it over. The record's
/// token says whether a later server adopted it, and the device's session lock says whether a
/// session is driving it right now, including one from an amoo that predates these records.
func reapLingeringCompanion(
    _ options: CompanionReapOptions,
    store: CompanionLingerStore = CompanionLingerStore(),
    sleep: @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
    deviceIsFree: @Sendable (String) -> Bool = { deviceID in
        guard let lock = try? DeviceAccessLock(deviceID: deviceID, store: DeviceRuntimeStore()) else { return false }
        lock.release()
        return true
    },
    stop: @Sendable (CompanionReapOptions) async -> Void = stopLingeringCompanion
) async -> CompanionReapOutcome {
    await sleep(options.afterSeconds)
    guard let linger = store.read(platform: options.platform.rawValue, port: options.port),
          linger.token == options.token
    else { return .superseded }
    guard deviceIsFree(options.deviceID) else {
        _ = store.remove(linger)
        return .inUse
    }
    guard store.remove(linger) else { return .superseded }
    await stop(options)
    return .stopped
}

@Sendable
func stopLingeringCompanion(_ options: CompanionReapOptions) async {
    switch options.platform {
    case .ios:
        var config = CompanionConfig(deviceUDID: options.deviceID)
        config.port = options.port
        // Only a runner whose launching process is gone is touched, never one a live amoo owns.
        _ = await CompanionManager().reclaimOrphanedCompanion(config: config)
    case .android:
        let config = AndroidCompanionConfig(
            port: options.port,
            serial: options.deviceID.isEmpty ? nil : options.deviceID
        )
        await AndroidCompanionManager().clearStaleCompanion(config: config)
    case .macos:
        break
    }
}

func runCompanionReap(arguments: [String]) async -> CLIResult {
    guard let options = CompanionReapOptions.parse(arguments) else {
        return CLIResult(
            output: "Usage: amoo companion reap --platform ios|android --device <id> --port <port>"
                + " --token <token> --after <seconds>",
            exitCode: 64
        )
    }
    let outcome = await reapLingeringCompanion(options)
    return CLIResult(output: "companion reap: \(outcome)", exitCode: 0)
}
