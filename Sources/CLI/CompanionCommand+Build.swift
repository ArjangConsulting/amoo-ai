import Foundation
import ProcessRunner

// MARK: - Build

/// `amoo companion build`: the one command that compiles a companion.
func runCompanionBuild(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner(),
    currentDirectory: String = FileManager.default.currentDirectoryPath
) async -> CLIResult {
    do {
        switch options.platform {
        case .ios, .macos:
            let target = options.platform == .macos ? options.forMac() : options
            let config = CompanionConfig(
                port: target.port ?? CompanionConfig.defaultPort,
                companionDir: target.companionDir,
                deviceUDID: target.deviceID
            )
            try await CompanionManager(processRunner: processRunner).build(config: config, force: options.force)
        case .android:
            let config = AndroidCompanionConfig(
                companionDir: options.companionDir
                    ?? AndroidCompanionConfig.defaultCompanionDir(currentDirectoryPath: currentDirectory),
                serial: nil
            )
            try await AndroidCompanionManager(processRunner: processRunner).build(config: config, force: options.force)
        }
        return CLIResult(output: "", exitCode: 0)
    } catch let error as CompanionError {
        return CLIResult(output: error.description, exitCode: 1)
    } catch let error as AndroidCompanionError {
        return CLIResult(output: error.description, exitCode: 1)
    } catch {
        return CLIResult(output: "Companion build failed: \(error)", exitCode: 1)
    }
}

// MARK: - iOS Install

func runIOSCompanionInstall(
    options: CompanionCommandOptions,
    processRunner: any ProcessRunner = SystemProcessRunner()
) async -> CLIResult {
    let config = CompanionConfig(
        port: options.port ?? CompanionConfig.defaultPort,
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
            ?? AndroidCompanionConfig.defaultCompanionDir(currentDirectoryPath: currentDirectory)

    let config = AndroidCompanionConfig(
        port: options.port ?? AndroidCompanionConfig.defaultPort,
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
