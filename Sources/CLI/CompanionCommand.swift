import Foundation
import GradleKit
import ProcessRunner
import SwiftyShell

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
    """
}

// swiftlint:disable:next cyclomatic_complexity
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

    var platform: CompanionPlatform = .ios
    var deviceID = "booted"
    var companionDir: String?
    var force = false
    var appID: String?

    while !remaining.isEmpty {
        let flag = remaining.removeFirst()
        switch flag {
        case "--platform":
            if let value = remaining.first {
                remaining.removeFirst()
                guard let p = CompanionPlatform(rawValue: value) else {
                    return .failure(.unknownPlatform(value))
                }
                platform = p
            }
        case "--device":
            if let value = remaining.first {
                deviceID = value
                remaining.removeFirst()
            }
        case "--companion-dir":
            if let value = remaining.first {
                companionDir = value
                remaining.removeFirst()
            }
        case "--app":
            if let value = remaining.first {
                appID = value
                remaining.removeFirst()
            }
        case "--force":
            force = true
        default:
            break
        }
    }

    return .success(
        CompanionCommandOptions(
            action: action,
            platform: platform,
            deviceID: deviceID,
            companionDir: companionDir,
            force: force,
            appID: appID
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
        try await manager.ensureRunning(config: config)
        let target = options.appID.map { " driving \($0)" } ?? ""
        print("Companion ready on port \(config.port)\(target).")
        print("Holding it open — Ctrl-C to stop, or run this in the background.")
        // The runner is spawned as a child of this process and is torn down with it, so returning
        // here would take the companion down a moment after announcing it was ready.
        try await Task.sleep(for: .seconds(60 * 60 * 24))
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
        try await manager.ensureRunning(config: config)
        print("Companion ready on port \(config.port).")
        print("Holding it open — Ctrl-C to stop, or run this in the background.")
        try await Task.sleep(for: .seconds(60 * 60 * 24))
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
