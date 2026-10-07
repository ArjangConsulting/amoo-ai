import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell

extension CompanionManager {
    func bundledProductsDirectory(config: CompanionConfig) -> String {
        let platform = config.isPhysicalDevice ? "iphoneos" : "iphonesimulator"
        return config.companionDir + "/prebuilt/\(platform)/Products"
    }

    /// Env vars `sign-prebuilt.py` needs to re-sign the unsigned release device products.
    static let deviceSigningEnvironmentKeys = [
        "AMOO_IOS_SIGNING_IDENTITY", "AMOO_IOS_HOST_PROFILE", "AMOO_IOS_RUNNER_PROFILE"
    ]

    /// Bundled products are only usable on a physical device when they can be re-signed. Without
    /// the signing environment the local Xcode-signed build is the only path that can work, so
    /// bundled products must not shadow it.
    func canSignBundledProducts(config: CompanionConfig) -> Bool {
        guard config.isPhysicalDevice else { return true }
        let environment = ProcessInfo.processInfo.environment
        return Self.deviceSigningEnvironmentKeys.allSatisfy { environment[$0]?.isEmpty == false }
    }

    func hasBundledProducts(config: CompanionConfig) -> Bool {
        guard config.buildMode != .rebuild, canSignBundledProducts(config: config),
              let bundled = findXCTestRun(productsDir: bundledProductsDirectory(config: config), config: config)
        else { return false }
        // A developer's freshly built companion must not be shadowed by an older distribution.
        // Explicit reuse keeps its release semantics; auto prefers newer local products.
        if config.buildMode == .auto,
           let local = findXCTestRun(productsDir: config.companionDir + "/build/Build/Products", config: config),
           let localDate = try? URL(fileURLWithPath: local).resourceValues(forKeys: [.contentModificationDateKey])
           .contentModificationDate,
           let bundledDate = try? URL(fileURLWithPath: bundled).resourceValues(forKeys: [.contentModificationDateKey])
           .contentModificationDate,
           localDate > bundledDate {
            return false
        }
        return true
    }

    func companionProductsDirectory(config: CompanionConfig, bundled: Bool? = nil) -> String {
        (bundled ?? hasBundledProducts(config: config))
            ? bundledProductsDirectory(config: config)
            : config.companionDir + "/build/Build/Products"
    }

    /// Booting and compilation are independent; launch joins both before using the simulator.
    func prepareSimulator(config: CompanionConfig) async throws {
        guard config.bootSimulator, !config.isPhysicalDevice else { return }
        await StartupProgress.report("Booting iOS simulator")
        let runner = processRunner
        // Bounded: an unresponsive simulator must surface as an error, not wedge the startup
        // (and the build error behind it, since `ensureRunning` joins this task on every exit).
        let boot = try await runner.run(Self.simctlRequest(["boot", config.deviceUDID], seconds: 60))
        guard boot.exitCode == 0 || boot.stderr.contains("current state: Booted") else {
            throw CompanionError.launchFailed("Simulator boot failed: \(boot.stderr)")
        }
        let ready = try await runner.run(Self.simctlRequest(["bootstatus", config.deviceUDID, "-b"], seconds: 300))
        guard ready.exitCode == 0 else {
            throw CompanionError.launchFailed("Simulator boot readiness failed: \(ready.stderr)")
        }
        await StartupProgress.report("iOS simulator boot complete; waiting for companion preparation")
    }

    private static func simctlRequest(_ arguments: [String], seconds: Int) -> ProcessExecutionRequest {
        ProcessExecutionRequest(
            command: Command("xcrun").args(["simctl"] + arguments).timeout(.seconds(seconds)),
            context: ShellContext()
        )
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
