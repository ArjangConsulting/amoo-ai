import Foundation
import GradleKit
import ProcessRunner
import SwiftyShell
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

// MARK: - Parsing

enum CompanionPlatform: String {
    case ios
    case android
}

struct CompanionCommandOptions {
    var action: CompanionAction
    var platform: CompanionPlatform
    var deviceID: String
    var companionDir: String?
    var force: Bool
    /// Bundle ID / package name of the app under test, bound as the gesture target.
    var appID: String?
}

enum CompanionAction {
    case install
    case start
}

enum CompanionCommandParseError: Error, CustomStringConvertible {
    case missingAction
    case unknownAction(String)
    case unknownPlatform(String)

    var description: String {
        switch self {
        case .missingAction:
            renderCompanionHelp()
        case let .unknownAction(action):
            "Unknown companion action '\(action)'. Run 'amoo companion' for usage."
        case let .unknownPlatform(p):
            "Unknown platform '\(p)'. Expected 'ios' or 'android'."
        }
    }
}

func renderCompanionHelp() -> String {
    """
    Usage: amoo companion <action> [options]

    Actions:
      install    Build and install the companion app on a device/simulator
                 Options:
                   --platform ios|android  Target platform (default: ios)
                   --device <id>           Simulator UDID or ADB serial (default: booted)
                   --companion-dir <path>  Override companion app directory
                   --force                 Force rebuild even if already built

      start      Build/install if needed, then run the companion and wait until it is
                 reachable, so `amoo device <tool>` can be used directly
                 Options:
                   --platform ios|android  Target platform (default: ios)
                   --device <id>           Simulator UDID or ADB serial (default: booted)
                   --app <bundle-id>       App under test, bound as the gesture target
                   --companion-dir <path>  Override companion app directory
                   --force                 Rebuild before starting
    """
}

private struct CompanionCommandFlags {
    var platform: CompanionPlatform = .ios
    var deviceID = "booted"
    var companionDir: String?
    var force = false
    var appID: String?
}

/// Consumes and returns the next token in `remaining`, if any, without failing when absent
/// (unrecognized-but-present flags with a missing value are silently ignored, matching the
/// original parser's leniency).
private func consumeOptionalValue(remaining: inout [String]) -> String? {
    guard let value = remaining.first else { return nil }
    remaining.removeFirst()
    return value
}

/// Applies one `--flag [value]` token to `flags`, consuming its value from `remaining` when
/// present. Returns a parse error only for a recognized flag with an invalid value.
private func applyCompanionFlag(
    _ flag: String,
    remaining: inout [String],
    flags: inout CompanionCommandFlags
) -> CompanionCommandParseError? {
    switch flag {
    case "--platform":
        guard let value = consumeOptionalValue(remaining: &remaining) else { return nil }
        guard let platform = CompanionPlatform(rawValue: value) else {
            return .unknownPlatform(value)
        }
        flags.platform = platform
    case "--device":
        flags.deviceID = consumeOptionalValue(remaining: &remaining) ?? flags.deviceID
    case "--companion-dir":
        flags.companionDir = consumeOptionalValue(remaining: &remaining) ?? flags.companionDir
    case "--app":
        flags.appID = consumeOptionalValue(remaining: &remaining) ?? flags.appID
    case "--force":
        flags.force = true
    default:
        break
    }
    return nil
}

/// Consumes `--flag [value]` tokens from `remaining` until exhausted.
private func parseCompanionFlags(
    remaining: inout [String]
) -> Result<CompanionCommandFlags, CompanionCommandParseError> {
    var flags = CompanionCommandFlags()

    while !remaining.isEmpty {
        let flag = remaining.removeFirst()
        if let error = applyCompanionFlag(flag, remaining: &remaining, flags: &flags) {
            return .failure(error)
        }
    }

    return .success(flags)
}

func parseCompanionCommandOptions(
    args: [String]
) -> Result<CompanionCommandOptions, CompanionCommandParseError> {
    var remaining = args

    guard let actionStr = remaining.first else {
        return .failure(.missingAction)
    }
    remaining.removeFirst()

    let action: CompanionAction
    switch actionStr {
    case "install":
        action = .install
    case "start":
        action = .start
    default:
        return .failure(.unknownAction(actionStr))
    }

    let flags: CompanionCommandFlags
    switch parseCompanionFlags(remaining: &remaining) {
    case let .success(parsed): flags = parsed
    case let .failure(error): return .failure(error)
    }

    return .success(
        CompanionCommandOptions(
            action: action,
            platform: flags.platform,
            deviceID: flags.deviceID,
            companionDir: flags.companionDir,
            force: flags.force,
            appID: flags.appID
        )
    )
}

// MARK: - Execution

func runCompanionCommand(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner(),
    currentDirectory: String = FileManager.default.currentDirectoryPath
) async -> CLIResult {
    switch options.action {
    case .install:
        switch options.platform {
        case .ios:
            await runIOSCompanionInstall(options: options, processRunner: processRunner)
        case .android:
            await runAndroidCompanionInstall(
                options: options,
                processRunner: processRunner,
                currentDirectory: currentDirectory
            )
        }
    case .start:
        switch options.platform {
        case .ios:
            await runIOSCompanionStart(options: options, processRunner: processRunner)
        case .android:
            await runAndroidCompanionStart(
                options: options,
                processRunner: processRunner,
                currentDirectory: currentDirectory
            )
        }
    }
}

// MARK: - Start

/// Brings the companion up and leaves it running.
///
/// Without this, the only ways to start a companion were `mcp serve` + `start_session`, `chat`, and
/// the REPL — so anyone driving `amoo device <tool>` straight from a shell got a bare
/// "Connection refused" on port 22087 with nothing telling them what to run.
func runIOSCompanionStart(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner()
) async -> CLIResult {
    let config = CompanionConfig(
        companionDir: options.companionDir,
        deviceUDID: options.deviceID,
        targetAppID: options.appID
    )
    let manager = CompanionManager(processRunner: processRunner)

    do {
        try await manager.ensureRunning(config: config, force: options.force)
        let target = options.appID.map { " driving \($0)" } ?? ""
        print("Companion ready on port \(config.port)\(target).")
        print("Holding it open — Ctrl-C to stop, or run this in the background.")
        // The runner is spawned as a child of this process and is torn down with it, so returning
        // here would take the companion down a moment after announcing it was ready.
        await waitForTerminationSignal()
        await manager.shutdown()
        return CLIResult(output: "", exitCode: 0)
    } catch is CancellationError {
        return CLIResult(output: "", exitCode: 0)
    } catch let error as CompanionError {
        return CLIResult(output: error.description, exitCode: 1)
    } catch {
        return CLIResult(output: "Companion start failed: \(error)", exitCode: 1)
    }
}

func runAndroidCompanionStart(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner(),
    currentDirectory: String = FileManager.default.currentDirectoryPath
) async -> CLIResult {
    let companionDir = options.companionDir ?? (currentDirectory + "/CompanionApps/Android")
    let config = AndroidCompanionConfig(companionDir: companionDir, serial: options.deviceID)
    let manager = AndroidCompanionManager(processRunner: processRunner)

    do {
        try await manager.ensureRunning(config: config, force: options.force)
        print("Companion ready on port \(config.port).")
        print("Holding it open — Ctrl-C to stop, or run this in the background.")
        await waitForTerminationSignal()
        await manager.shutdown()
        return CLIResult(output: "", exitCode: 0)
    } catch is CancellationError {
        return CLIResult(output: "", exitCode: 0)
    } catch let error as AndroidCompanionError {
        return CLIResult(output: error.description, exitCode: 1)
    } catch {
        return CLIResult(output: "Android companion start failed: \(error)", exitCode: 1)
    }
}

// MARK: - iOS Install

func runIOSCompanionInstall(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner()
) async -> CLIResult {
    let config = CompanionConfig(
        companionDir: options.companionDir,
        deviceUDID: options.deviceID
    )
    let manager = CompanionManager(processRunner: processRunner)

    do {
        try await manager.install(config: config, force: options.force)
        return CLIResult(output: "", exitCode: 0)
    } catch let error as CompanionError {
        return CLIResult(output: error.description, exitCode: 1)
    } catch {
        return CLIResult(output: "Companion install failed: \(error)", exitCode: 1)
    }
}

// MARK: - Android Install

func runAndroidCompanionInstall(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner(),
    currentDirectory: String = FileManager.default.currentDirectoryPath
) async -> CLIResult {
    let companionDir =
        options.companionDir
            ?? (currentDirectory + "/CompanionApps/Android")

    let config = AndroidCompanionConfig(
        companionDir: companionDir,
        serial: options.deviceID
    )
    let manager = AndroidCompanionManager(processRunner: processRunner)

    do {
        try await manager.install(config: config, force: options.force)
        return CLIResult(output: "", exitCode: 0)
    } catch let error as AndroidCompanionError {
        return CLIResult(output: error.description, exitCode: 1)
    } catch {
        return CLIResult(output: "Android companion install failed: \(error)", exitCode: 1)
    }
}

// MARK: - Foreground lifecycle

private final class CompanionSignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []
    private var finished = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            #if os(macOS) || os(Linux)
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let created = [SIGINT, SIGTERM].map { signalNumber in
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
                source.setEventHandler { [weak self] in self?.finish() }
                source.resume()
                return source
            }
            // A signal can arrive between `resume()` and this assignment, so `finish()` may
            // already have run and cleared the (then empty) source list. Cancel here instead of
            // storing sources that nothing will ever tear down.
            lock.lock()
            let alreadyFinished = finished
            if !alreadyFinished {
                sources = created
            }
            lock.unlock()
            if alreadyFinished {
                created.forEach { $0.cancel() }
            }
            #else
            finish()
            #endif
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let pending = continuation
        continuation = nil
        let activeSources = sources
        sources = []
        lock.unlock()

        activeSources.forEach { $0.cancel() }
        pending?.resume()
    }
}

private func waitForTerminationSignal() async {
    await CompanionSignalWaiter().wait()
}
