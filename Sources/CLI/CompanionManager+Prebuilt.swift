import AmooCore
import Foundation
import MobileDevices
import ProcessRunner
import SwiftyShell
import SwiftyTerminal

extension CompanionManager: IOSCompanionManaging {}

extension CompanionManager {
    /// Checks that a companion build exists. iOS installs the bundle when it launches, so there is
    /// nothing to copy ahead of time; building is `build(config:force:)`, never this.
    func install(config: CompanionConfig, force _: Bool = false) async throws {
        let productsDir = companionProductsDirectory(config: config)
        guard findXCTestRun(productsDir: productsDir, config: config) != nil else {
            throw CompanionError.buildFailed(Self.missingBuildMessage(config: config))
        }
        let bundled = hasBundledProducts(config: config)
        if sourcesChanged(config: config, bundled: bundled) {
            print(styled(staleNotice(config: config, bundled: bundled), .yellow))
        }
        print(styled("Companion already built.", .green) + styled(" `amoo companion build` rebuilds it.", .gray))
        print(styled("This does not start it — run 'amoo companion start' to bring it up.", .gray))
    }

    /// `amoo companion build`: compiles the companion from its sources when no current build exists,
    /// or always with `force`. The only route that compiles besides an explicit `build_mode=rebuild`.
    func build(config: CompanionConfig, force: Bool = false) async throws {
        let productsDir = config.companionDir + "/build/Build/Products"
        if !force, findXCTestRun(productsDir: productsDir, config: config) != nil,
           sourceFingerprintMatches(config: config) {
            // Says "built", never "installed" or "running" — a previous build product on disk is
            // all this proves. Reporting it as plain success is what made a dead companion look
            // like a healthy one: nothing was on the device and nothing was listening on the port.
            print(styled("Companion is up to date with its sources.", .green) + styled(" --force rebuilds.", .gray))
            return
        }
        var rebuild = config
        rebuild.buildMode = .rebuild
        print("Building companion app (this may take a moment)...")
        try await withSpinner("Building companion app") {
            try await buildForTesting(config: rebuild)
        }
        print(styled("Companion built.", .green))
    }

    /// Compiles the companion, records the `build` phase, and returns the new `.xctestrun`.
    func buildRecordingPhase(config: CompanionConfig) async throws -> String? {
        let phaseStart = ContinuousClock.now
        await StartupProgress.report("Building iOS companion (in parallel with simulator boot)")
        print("Companion sources changed or no build exists. Building (this may take a moment)...")
        try await withSpinner("Building companion app") {
            try await buildForTesting(config: config)
        }
        CompanionStartPhases.shared.record("build", outcome: "built", since: phaseStart)
        return findXCTestRun(productsDir: config.companionDir + "/build/Build/Products", config: config)
    }

    /// Xcode omits the UI-test group's entitlement from the generated simulator executable.
    func signSimulatorProducts(config: CompanionConfig) async throws {
        guard !config.isPhysicalDevice, !config.isMac else { return }
        let result = try await processRunner.run([
            "python3", config.companionDir + "/sign-simulator-products.py",
            config.companionDir + "/build/Build/Products"
        ])
        guard result.exitCode == 0 else {
            throw CompanionError.buildFailed("Simulator companion signing failed: \(result.stderr)")
        }
    }

    func bundledProductsDirectory(config: CompanionConfig) -> String {
        config.companionDir + "/prebuilt/\(config.productPlatform)/Products"
    }

    /// The error for a start that found no companion build: starts never compile one.
    static func missingBuildMessage(config: CompanionConfig) -> String {
        let platform = config.isMac ? "macos" : "ios"
        return "No built \(platform == "macos" ? "macOS" : "iOS") companion in \(config.companionDir)."
            + " Starting a device never builds one; run `amoo companion build --platform \(platform)`"
            + " (or `make companion-build` in an amoo checkout), then start again."
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
        // Bounded: an unresponsive simulator must surface as an error, not wedge the startup
        // (and the build error behind it, since `ensureRunning` joins this task on every exit).
        // One that misses the window is shut down and booted once more before that error.
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        do {
            try await SimulatorBootRecovery.boot(config.deviceUDID, shell: context)
        } catch {
            throw CompanionError.launchFailed("Simulator boot readiness failed: \(error)")
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
