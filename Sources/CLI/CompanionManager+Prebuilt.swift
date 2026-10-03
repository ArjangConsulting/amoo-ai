import AmooCore
import Foundation
import ProcessRunner

extension CompanionManager {
    func bundledProductsDirectory(config: CompanionConfig) -> String {
        let platform = config.isPhysicalDevice ? "iphoneos" : "iphonesimulator"
        return config.companionDir + "/prebuilt/\(platform)/Products"
    }

    func hasBundledProducts(config: CompanionConfig) -> Bool {
        config.buildMode != .rebuild
            && findXCTestRun(productsDir: bundledProductsDirectory(config: config), config: config) != nil
    }

    func companionProductsDirectory(config: CompanionConfig) -> String {
        hasBundledProducts(config: config)
            ? bundledProductsDirectory(config: config)
            : config.companionDir + "/build/Build/Products"
    }

    /// Booting and compilation are independent; launch joins both before using the simulator.
    func prepareSimulator(config: CompanionConfig) async throws {
        guard config.bootSimulator, !config.isPhysicalDevice else { return }
        await StartupProgress.report("Booting iOS simulator")
        let runner = processRunner
        let result = try await runner.run(["xcrun", "simctl", "boot", config.deviceUDID])
        guard result.exitCode == 0 || result.stderr.contains("current state: Booted") else {
            throw CompanionError.launchFailed("Simulator boot failed: \(result.stderr)")
        }
        let ready = try await runner.run(["xcrun", "simctl", "bootstatus", config.deviceUDID, "-b"])
        guard ready.exitCode == 0 else {
            throw CompanionError.launchFailed("Simulator boot readiness failed: \(ready.stderr)")
        }
        await StartupProgress.report("iOS simulator boot complete; waiting for companion preparation")
    }

    /// Release device builds are unsigned. Sign a writable copy with the user's profiles.
    func signedTestRunIfNeeded(_ path: String, config: CompanionConfig) async throws -> String {
        guard config.isPhysicalDevice, path.contains("/prebuilt/") else { return path }
        await StartupProgress.report("Signing prebuilt iOS companion for the physical device")
        let script = config.companionDir + "/sign-prebuilt.py"
        let result = try await processRunner.run(["python3", script, path, config.deviceUDID])
        guard result.exitCode == 0 else {
            throw CompanionError.launchFailed("Prebuilt companion signing failed: \(result.stderr)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
