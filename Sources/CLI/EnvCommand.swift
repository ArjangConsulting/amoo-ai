import AmooCore
import Foundation

// MARK: - Options

/// `amoo env up|down|list`: deterministic, non-interactive test-environment setup for agents.
enum EnvAction: Equatable {
    case up(EnvUpOptions)
    case down(EnvDownOptions)
    case list(json: Bool)
}

struct EnvUpOptions: Equatable {
    var runtimeID: String?
    var platform: Platform = .android
    /// Simulator UDID / emulator serial. Must be a simulator or emulator.
    var deviceID: String?
    /// Android: AVD to reuse (if running) or boot.
    var avd: String?
    /// iOS: runtime such as `iOS-27.0`, `iOS 27.0` or `27.0`.
    var runtime: String?
    /// iOS: simulator model name, e.g. `iPhone 17e`.
    var model: String?
    /// Companion port; `nil` picks a free one.
    var port: Int?
    /// App artifact to install (`.apk` / `.app`).
    var appPath: String?
    /// Bundle id / package name of the app under test.
    var appID: String?
    /// Digest of `appPath` when the caller already computed it (init hashes once for all devices).
    var appSHA256: String?
    var launch = false
    var owner: String?
    var ttlMinutes: Int?
    var readyTimeoutSeconds: Int?
    var json = false
}

struct EnvDownOptions: Equatable {
    var runtimeID: String?
    var deviceID: String?
    /// Also shut the device down (only when `env up` booted it, unless `force`).
    var shutdown = false
    /// Allow shutting down a device that this runtime did not boot.
    var force = false
    var json = false
}

enum EnvCommandParseError: Error, CustomStringConvertible, Equatable {
    case usage(String)

    var description: String {
        switch self {
        case let .usage(message): message + "\n\n" + renderEnvHelp()
        }
    }
}

func renderEnvHelp() -> String {
    """
    Usage: amoo env <up|down|list> [options]

    Start or stop amoo on simulators and emulators. A runtime tracks the companion process;
    device access coordination prevents simultaneous control by different sessions.

      up     --platform ios|android
             [--device <udid|emulator-serial>]
             [--avd <name>]
             [--runtime <iOS-27.0>] [--model <name>]
             [--runtime-id <id>]                      reuse an owned, running runtime
             [--port <n>]                             default: first free 22093+
             [--app <path.apk|path.app>] [--app-id <id>] [--launch]
             [--owner <label>] [--ttl <minutes>] [--ready-timeout <secs>] [--json]
             Later calls can use --runtime-id <id> or AMOO_RUNTIME_ID.

      down   --device <id> | --runtime-id <id> [--shutdown] [--force] [--json]
             Stops the companion and removes its runtime record, including stale records.
             --shutdown also stops a device booted by env up; --force permits shutting down
             an already booted device. An active session always prevents stopping its device.

      list   [--json]   Runtime records with observed starting, running, unresponsive or stale state.

    Installed means the companion app is installed. Running means its API is reachable.
    Exit codes: 0 ok, 1 failed, 3 device is being controlled by another session.
    """
}

func parseEnvCommand(args: [String]) -> Result<EnvAction, EnvCommandParseError> {
    guard let action = args.first else { return .failure(.usage("Missing env action.")) }
    var flags = EnvFlagReader(Array(args.dropFirst()))
    do {
        switch action {
        case "up": return try .success(.up(parseEnvUp(&flags)))
        case "down": return try .success(.down(parseEnvDown(&flags)))
        case "list":
            let json = flags.take("--json")
            try flags.finish()
            return .success(.list(json: json))
        default:
            return .failure(.usage("Unknown env action '\(action)'."))
        }
    } catch let error as EnvCommandParseError {
        return .failure(error)
    } catch {
        return .failure(.usage("\(error)"))
    }
}

private func parseEnvUp(_ flags: inout EnvFlagReader) throws -> EnvUpOptions {
    var options = EnvUpOptions()
    guard let platform = try flags.value("--platform").flatMap({ Platform(rawValue: $0.lowercased()) }) else {
        throw EnvCommandParseError.usage("env up needs --platform ios|android.")
    }
    options.platform = platform
    options.deviceID = try flags.value("--device")
    options.runtimeID = try flags.value("--runtime-id")
    options.avd = try flags.value("--avd")
    options.runtime = try flags.value("--runtime")
    options.model = try flags.value("--model")
    options.port = try flags.int("--port")
    options.appPath = try flags.value("--app")
    options.appID = try flags.value("--app-id")
    options.launch = flags.take("--launch")
    options.owner = try flags.value("--owner")
    options.ttlMinutes = try flags.int("--ttl")
    options.readyTimeoutSeconds = try flags.int("--ready-timeout")
    options.json = flags.take("--json")
    try flags.finish()
    if options.launch, options.appID == nil {
        throw EnvCommandParseError.usage("--launch needs --app-id.")
    }
    if platform == .ios, options.avd != nil {
        throw EnvCommandParseError.usage("--avd is Android-only; use --runtime/--model for iOS.")
    }
    return options
}

private func parseEnvDown(_ flags: inout EnvFlagReader) throws -> EnvDownOptions {
    var options = EnvDownOptions()
    options.runtimeID = try flags.value("--runtime-id")
    options.deviceID = try flags.value("--device")
    options.shutdown = flags.take("--shutdown")
    options.force = flags.take("--force")
    options.json = flags.take("--json")
    try flags.finish()
    guard options.runtimeID != nil || options.deviceID != nil else {
        throw EnvCommandParseError.usage("env down needs --runtime-id <id> or --device <id>.")
    }
    return options
}

/// Order-independent `--flag [value]` reader that rejects anything left over, so a typo fails
/// fast instead of being ignored.
struct EnvFlagReader {
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    mutating func take(_ flag: String) -> Bool {
        guard let index = tokens.firstIndex(of: flag) else { return false }
        tokens.remove(at: index)
        return true
    }

    mutating func value(_ flag: String) throws -> String? {
        guard let index = tokens.firstIndex(of: flag) else { return nil }
        guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
            throw EnvCommandParseError.usage("\(flag) needs a value.")
        }
        let value = tokens[index + 1]
        tokens.removeSubrange(index ... index + 1)
        return value
    }

    mutating func int(_ flag: String) throws -> Int? {
        guard let raw = try value(flag) else { return nil }
        guard let parsed = Int(raw), parsed > 0 else {
            throw EnvCommandParseError.usage("\(flag) expects a positive number, got '\(raw)'.")
        }
        return parsed
    }

    func firstPositionalIndex() -> Int? {
        tokens.firstIndex { !$0.hasPrefix("--") }
    }

    mutating func removeToken(at index: Int) -> String {
        tokens.remove(at: index)
    }

    func finish() throws {
        guard tokens.isEmpty else {
            throw EnvCommandParseError.usage("Unexpected argument(s): \(tokens.joined(separator: " ")).")
        }
    }
}

// MARK: - Pure selection helpers

/// Normalizes `iOS-27.0`, `iOS 27.0`, `27` and `27.0` to `27.0`.
func normalizedIOSRuntime(_ raw: String) -> String {
    let digits = raw.lowercased()
        .replacingOccurrences(of: "ios", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        .replacingOccurrences(of: "-", with: ".")
    return digits.contains(".") ? digits : digits + ".0"
}

/// Picks a simulator for `env up`: matching runtime/model, not controlled by anyone else, booted ones
/// first (reuse is cheaper than a boot).
func pickIOSSimulator(
    runtime: String?,
    model: String?,
    available: [IOSSimulatorDevice],
    bootedUDIDs: Set<String>,
    isControlled: (String) -> Bool
) -> IOSSimulatorDevice? {
    let wantedRuntime = runtime.map(normalizedIOSRuntime)
    let candidates = available.filter { simulator in
        (wantedRuntime == nil || simulator.osVersion == wantedRuntime)
            && (model == nil || simulator.name.lowercased() == model?.lowercased())
            && !isControlled(simulator.udid)
    }
    return candidates.first { bootedUDIDs.contains($0.udid) } ?? candidates.first
}

/// The first port in `candidates` that is neither listening nor claimed by a runtime.
func pickFreeCompanionPort(
    candidates: ClosedRange<Int> = 22093 ... 22199,
    reservedPorts: Set<Int>,
    isListening: (Int) async -> Bool
) async -> Int? {
    for port in candidates where !reservedPorts.contains(port) {
        if await !isListening(port) {
            return port
        }
    }
    return nil
}
