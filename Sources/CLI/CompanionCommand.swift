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
}

enum CompanionAction {
    case install
}

enum CompanionCommandParseError: Error, CustomStringConvertible {
    case missingAction
    case unknownAction(String)
    case unknownPlatform(String)

    var description: String {
        switch self {
        case .missingAction:
            """
            Usage: mobile-testing companion <action> [options]

            Actions:
              install    Build and install the companion app on a device/simulator
                         Options:
                           --platform ios|android  Target platform (default: ios)
                           --device <id>           Simulator UDID or ADB serial (default: booted)
                           --companion-dir <path>  Override companion app directory
                           --force                 Force rebuild even if already built
            """
        case let .unknownAction(action):
            "Unknown companion action '\(action)'. Run 'mobile-testing companion' for usage."
        case let .unknownPlatform(p):
            "Unknown platform '\(p)'. Expected 'ios' or 'android'."
        }
    }
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
    default:
        return .failure(.unknownAction(actionStr))
    }

    var platform: CompanionPlatform = .ios
    var deviceID = "booted"
    var companionDir: String?
    var force = false

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
            force: force
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

    let appApkPath = companionDir + "/app/build/outputs/apk/debug/app-debug.apk"
    let testApkPath =
        companionDir + "/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

    let needsBuild =
        options.force
            || !FileManager.default.fileExists(atPath: appApkPath)
            || !FileManager.default.fileExists(atPath: testApkPath)

    if needsBuild {
        print("Building Android companion (this may take a moment)...")
        let gradlewPath = companionDir + "/gradlew"
        do {
            let result = try await withCLILoadingIndicator("Building Android companion") {
                try await Gradle(context: shellContext(processRunner: processRunner))
                    .settingGradlewPath(gradlewPath)
                    .updatingConfiguration { $0.workingDirectory(companionDir) }
                    .task(.assembleDebug)
                    .task(.custom("assembleAndroidTest"))
                    .run()
                    .processResult
            }
            if result.exitCode != 0 {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                return CLIResult(output: "Android companion build failed:\n\(message)", exitCode: 1)
            }
        } catch {
            return CLIResult(output: "Android companion build failed: \(error)", exitCode: 1)
        }
    }

    print("Installing Android companion APKs...")
    let installFailure = await withCLILoadingIndicator("Installing Android companion APKs") {
        () async -> String? in
        for (label, apkPath) in [("app", appApkPath), ("test", testApkPath)] {
            let result: ProcessResult
            do {
                result = try await Adb(context: shellContext(processRunner: processRunner))
                    .serial(options.deviceID == "booted" ? nil : options.deviceID)
                    .install(apk: apkPath, replace: true)
                    .run()
                    .processResult
            } catch {
                return "Android install failed: \(error)"
            }
            if result.exitCode != 0 {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                return "Failed to install Android \(label) APK:\n\(message)"
            }
        }
        return nil
    }
    if let installFailure {
        return CLIResult(output: installFailure, exitCode: 1)
    }

    print("Android companion installed successfully.")
    return CLIResult(output: "", exitCode: 0)
}

private func shellContext(processRunner: any ProcessRunner) -> ShellContext {
    ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
}
