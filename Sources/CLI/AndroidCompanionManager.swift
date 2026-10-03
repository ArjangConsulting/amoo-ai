import AmooCore
import Foundation
import GradleKit
import ProcessRunner
import SwiftyShell

// MARK: - Configuration

struct AndroidCompanionConfig {
    var buildMode: SessionBuildMode = .auto
    var buildPrepared = false
    var installPreparedBuild = false
    var host: String
    var port: Int
    var companionDir: String
    var serial: String?
    var readyTimeoutSeconds: Int

    /// The port an Android companion listens on unless told otherwise.
    static let defaultPort = 22088

    /// Emulator console ports are even numbers 5554…5584; each maps to one port from `defaultPort`.
    private static let emulatorConsolePorts = 5554 ... 5584
    /// First port used for devices that are not emulators; sits above the 16 emulator slots.
    static let fallbackPortBase = defaultPort + 16
    static let maxPort = 65535

    /// The fixed companion port for an `emulator-<console port>` serial, or nil for other devices.
    static func emulatorPort(forSerial serial: String) -> Int? {
        guard serial.hasPrefix("emulator-"),
              let console = Int(serial.dropFirst("emulator-".count)),
              emulatorConsolePorts.contains(console), console.isMultiple(of: 2)
        else { return nil }
        return defaultPort + (console - emulatorConsolePorts.lowerBound) / 2
    }

    init(
        host: String = "127.0.0.1",
        port: Int = Self.defaultPort,
        companionDir: String? = nil,
        serial: String?,
        readyTimeoutSeconds: Int = Self.defaultReadyTimeoutSeconds
    ) {
        self.host = host
        self.port = port
        self.companionDir = companionDir ?? Self.defaultCompanionDir()
        self.serial = (serial?.isEmpty == false && serial != "booted") ? serial : nil
        self.readyTimeoutSeconds = readyTimeoutSeconds
    }

    /// Android's instrumentation launch is far quicker than Xcode's, but a cold emulator under
    /// load still exceeds the old 60s. Same reasoning as the iOS default: over-waiting costs time
    /// only when something is genuinely broken, under-waiting reports working setups as broken.
    /// Override with `--ready-timeout <seconds>` or `AMOO_COMPANION_READY_TIMEOUT`.
    static let defaultReadyTimeoutSeconds = 180

    static func readyTimeoutFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment["AMOO_COMPANION_READY_TIMEOUT"],
              let seconds = Int(raw), seconds > 0
        else { return defaultReadyTimeoutSeconds }
        return seconds
    }

    /// The companion lives next to the amoo installation, not next to whoever invoked it.
    ///
    /// Mirrors `CompanionManager.defaultCompanionDir()`, which was fixed for this exact reason on
    /// the iOS side: resolving against the current working directory made every invocation from
    /// another project fail on a `CompanionApps/Android/gradlew` path the caller has no reason to
    /// have. The executable's own location is walked upward instead, with the CWD kept as a last
    /// resort for running out of a source checkout.
    static func defaultCompanionDir(
        executableURL: URL? = Bundle.main.executableURL,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> String {
        let fileManager = FileManager.default
        var searchRoots: [URL] = []

        // `CommandLine.arguments[0]` is often only "amoo" when invoked through PATH, which
        // incorrectly resolves relative to the caller's working directory. Bundle supplies the
        // actual executable URL for command-line tools, including Homebrew-style symlinks.
        if var executableDir = executableURL?
            .resolvingSymlinksInPath()
            .deletingLastPathComponent() {
            for _ in 0 ..< 6 {
                searchRoots.append(executableDir)
                executableDir.deleteLastPathComponent()
            }
        }
        searchRoots.append(URL(fileURLWithPath: currentDirectoryPath))

        for root in searchRoots {
            let candidate = root.appendingPathComponent("CompanionApps/Android")
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("gradlew").path) {
                return candidate.path
            }
        }

        return currentDirectoryPath + "/CompanionApps/Android"
    }
}

// MARK: - Errors

enum AndroidCompanionError: Error, CustomStringConvertible {
    case buildFailed(String)
    case installFailed(String)
    case launchFailed(String)
    case readyTimeout(seconds: Int, port: Int)

    var description: String {
        switch self {
        case let .buildFailed(reason):
            "Android companion build failed: \(reason)"
        case let .installFailed(reason):
            "Android companion install failed: \(reason)"
        case let .launchFailed(reason):
            "Android companion launch failed: \(reason)"
        case let .readyTimeout(seconds, port):
            """
            Android companion did not become reachable after \(seconds)s. A companion left \
            running by an earlier session can hold port \(port) in a half-open state that passes \
            a TCP check but never serves gRPC. Recover with:
              adb shell am force-stop com.amoo.companion
              adb forward --remove tcp:\(port)
            then retry (optionally with a larger --ready-timeout).
            """
        }
    }
}

// MARK: - AndroidCompanionManager

/// Host-side lifecycle for the Android companion: build (Gradle), install
/// app + test APKs, forward TCP, spawn the instrumentation runner, wait for
/// reachability, and tear everything down on shutdown.
protocol AndroidCompanionManaging: Sendable {
    func ensureRunning(config: AndroidCompanionConfig, force: Bool) async throws
    func prepareBuild(config: AndroidCompanionConfig) async throws -> Bool
    /// The host port the companion for `serial` is reachable on. Distinct per device so that
    /// concurrent sessions on different emulators do not share a port.
    func companionPort(forSerial serial: String) async -> Int
}

extension AndroidCompanionManaging {
    func prepareBuild(config _: AndroidCompanionConfig) async throws -> Bool {
        false
    }

    func companionPort(forSerial _: String) async -> Int {
        AndroidCompanionConfig.defaultPort
    }
}

final class AndroidCompanionManager: @unchecked Sendable {
    /// A companion this manager launched for one device.
    struct RunningCompanion {
        var process: (any SpawnedProcess)?
        var config: AndroidCompanionConfig
    }

    /// Per-device state, keyed by serial (`""` for the default device). Guarded by `stateLock`,
    /// which is never held across an `await`: sessions on different emulators run concurrently.
    var running: [String: RunningCompanion] = [:]
    var fallbackPorts: [String: Int] = [:]
    let stateLock = NSLock()
    let shellContext: ShellContext

    init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        // Gradle inherits JAVA_HOME from here. AGP 8.7 cannot run on a JDK newer than 21, and
        // the failures it produces name neither Java nor the JDK — see `AndroidJDK`.
        shellContext = ShellContext(
            executor: ProcessRunnerCommandExecutor(processRunner: processRunner),
            environment: AndroidJDK.gradleEnvironment()
        )
    }

    /// Builds + installs the companion APKs (no launch). Used by `amoo companion install --platform android`.
    func install(config: AndroidCompanionConfig, force: Bool = false) async throws {
        // `--force` reinstalls bundled APKs; it only recompiles when there are none to install.
        let (appApk, testApk) = apkPaths(
            companionDir: config.companionDir,
            useBundled: config.buildMode != .rebuild
        )
        let needsBuild = (force && !appApk.contains("/prebuilt/"))
            || !FileManager.default.fileExists(atPath: appApk)
            || !FileManager.default.fileExists(atPath: testApk)

        if needsBuild, config.buildMode == .reuse {
            throw AndroidCompanionError
                .buildFailed("No cached Android companion; install prebuilt companions or use build_mode=auto once.")
        }
        if needsBuild {
            await StartupProgress.report("Building Android companion")
            print("Building Android companion (this may take a moment)...")
            try await withCLILoadingIndicator("Building Android companion") {
                try await self.buildAPKs(config: config)
            }
        } else {
            print(colored("Android companion already built.", .green) + colored(" Use --force to rebuild.", .gray))
        }

        await StartupProgress.report("Installing Android companion APKs")
        print("Installing Android companion APKs...")
        try await withCLILoadingIndicator("Installing Android companion APKs") {
            try await self.installAPKs(config: config, appApkPath: appApk, testApkPath: testApk)
        }
        print(colored("Android companion installed successfully.", .green))
    }

    // swiftlint:disable function_body_length - linear startup lifecycle with rollback.
    /// Ensures the companion is reachable. Builds, installs, forwards TCP, spawns
    /// the instrumentation runner, and waits for the gRPC port — only as needed.
    func ensureRunning(config: AndroidCompanionConfig, force: Bool = false) async throws {
        await StartupProgress.report("Checking Android companion")
        let bundled = hasBundledAPKs(companionDir: config.companionDir)
        let sourcesChanged = !config.buildPrepared &&
            (config.buildMode == .rebuild ||
                (config.buildMode != .reuse && !bundled && !sourceFingerprintMatches(config: config)))
        let requiresReplacement = config.installPreparedBuild || sourcesChanged
        if force {
            if tracked(serial: config.serial) == nil {
                await clearStaleCompanion(config: config)
            } else {
                await shutdown(serial: config.serial)
            }
        }

        if !force, !requiresReplacement,
           !isPortHeldByOtherDevice(config: config),
           await isCompanionReady(host: config.host, port: config.port) {
            print("Android companion already running on port \(config.port) for"
                + " \(config.serial ?? "default device").")
            return
        }

        // Do not leave a wedged instrumentation runner behind when starting its replacement.
        if tracked(serial: config.serial) != nil {
            await shutdown(serial: config.serial)
        }

        if await isReachable(host: config.host, port: config.port), requiresReplacement {
            await clearStaleCompanion(config: config)
        }

        let (appApk, testApk) = apkPaths(
            companionDir: config.companionDir,
            useBundled: config.buildMode != .rebuild
        )
        let needsBuild = (force && !bundled)
            || sourcesChanged
            || !FileManager.default.fileExists(atPath: appApk)
            || !FileManager.default.fileExists(atPath: testApk)

        if needsBuild, config.buildMode == .reuse {
            throw AndroidCompanionError
                .buildFailed("No cached Android companion; install prebuilt companions or use build_mode=auto once.")
        }
        if needsBuild {
            await StartupProgress.report("Building Android companion")
            print("Android companion sources changed or no build exists."
                + " Building (this may take a moment)...")
            try await withCLILoadingIndicator("Building Android companion") {
                try await self.buildAPKs(config: config)
            }
        }

        await StartupProgress.report("Installing Android companion APKs")
        print("Installing Android companion APKs...")
        try await withCLILoadingIndicator("Installing Android companion APKs") {
            try await self.installAPKs(config: config, appApkPath: appApk, testApkPath: testApk)
        }

        // Always clear a stale instance before (re)launching. We only reach here because the
        // companion is not already serving, so anything still holding the port is dead and would
        // otherwise wedge the launch below.
        print("Clearing any stale Android companion on port \(config.port)...")
        await clearStaleCompanion(config: config)

        print("Forwarding 127.0.0.1:\(config.port) → device:\(config.port)...")
        try await forwardPort(config: config)

        await StartupProgress.report("Launching Android companion instrumentation")
        print("Starting Android companion instrumentation on port \(config.port)...")
        let process = try await launchInstrumentation(config: config)
        setTracked(RunningCompanion(process: process, config: config))

        // `--ready-timeout` (default 180s / `AMOO_COMPANION_READY_TIMEOUT`) bounds the wait for the
        // gRPC port. `waitUntilReachable` enforces it on the poll loop; the surrounding task-group
        // race is the backstop for a wedged `adb` call in between, so the command fails with a
        // recovery hint instead of hanging silently.
        try await withReadyDeadline(seconds: config.readyTimeoutSeconds, port: config.port) {
            try await withCLILoadingIndicator("Waiting for Android companion on port \(config.port)") {
                try await self.waitUntilReachable(
                    host: config.host,
                    port: config.port,
                    timeoutSeconds: config.readyTimeoutSeconds
                )
            }
        }
        print(colored("Android companion ready.", .bold, .green))
    }

    // swiftlint:enable function_body_length

    /// Runs `operation` with an outer wall-clock cap of `seconds` + a fixed slack, so a hung `adb`
    /// invocation surfaces as `.readyTimeout` rather than an unbounded wait. The inner
    /// `waitUntilReachable` normally trips first (and keeps its launch-log dump); this only wins
    /// when something upstream of the poll loop stops making progress.
    private func withReadyDeadline(
        seconds: Int,
        port: Int,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let budget = seconds + 30
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(Double(budget)))
                throw AndroidCompanionError.readyTimeout(seconds: budget, port: port)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Returns once the runner this manager spawned exits, reporting its exit code and log.
    /// Never returns when this process spawned none — it is only attached to another holder's
    /// companion, whose lifetime is not its to manage.
    func waitForRunnerExit() async {
        guard let process = firstTrackedProcess() else {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            return
        }
        let output = await process.waitForExit()
        guard !Task.isCancelled else { return }
        print(colored("Companion runner exited (code \(output.exitCode)).", .bold, .red))
    }

    // MARK: - Private

    /// True only when both prebuilt APKs exist; a partial `prebuilt/` is not a usable bundle.
    func hasBundledAPKs(companionDir: String) -> Bool {
        FileManager.default.fileExists(atPath: companionDir + "/prebuilt/app-debug.apk")
            && FileManager.default.fileExists(atPath: companionDir + "/prebuilt/app-debug-androidTest.apk")
    }

    func apkPaths(companionDir: String, useBundled: Bool = true) -> (app: String, test: String) {
        if useBundled, hasBundledAPKs(companionDir: companionDir) {
            return (companionDir + "/prebuilt/app-debug.apk", companionDir + "/prebuilt/app-debug-androidTest.apk")
        }
        let app = companionDir + "/app/build/outputs/apk/debug/app-debug.apk"
        let test = companionDir + "/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
        return (app, test)
    }

    /// Builds the APKs, joining a build already running for the same companion directory.
    func buildAPKs(config: AndroidCompanionConfig) async throws {
        try await Self.buildCoordinator.build(key: config.companionDir) {
            try await self.runGradleBuild(config: config)
        }
    }

    private func runGradleBuild(config: AndroidCompanionConfig) async throws {
        // Hash before building: a source edit made while Gradle runs must leave the fingerprint
        // stale so the next session rebuilds, rather than being recorded as already built.
        let fingerprint = currentSourceFingerprint(config: config)
        let gradlewPath = config.companionDir + "/gradlew"
        let result: ProcessResult
        do {
            result = try await Gradle(context: shellContext)
                .settingGradlewPath(gradlewPath)
                .updatingConfiguration { $0.workingDirectory(config.companionDir) }
                .task(.assembleDebug)
                .task(.custom("assembleAndroidTest"))
                .run()
                .processResult
        } catch {
            throw AndroidCompanionError.buildFailed(error.localizedDescription)
        }
        if result.exitCode != 0 {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AndroidCompanionError.buildFailed(message)
        }
        try writeSourceFingerprint(config: config, fingerprint: fingerprint)
    }

    /// Force-stops both companion packages and drops the TCP forward, so a companion left behind
    /// by a prior or crashed session cannot hold the port.
    ///
    /// `am instrument` only ever force-stops the `.test` package, but the gRPC server runs inside
    /// `com.amoo.companion` itself — so a stale server process keeps `:22088` bound in a half-open
    /// state (`FIN_WAIT2` / `CLOSE_WAIT`) that a bare TCP probe accepts while every gRPC call is
    /// refused. Left in place it makes `waitUntilReachable` burn the full `--ready-timeout` with
    /// no diagnostic. Safe to call when nothing is running; costs ~1s.
    func clearStaleCompanion(config: AndroidCompanionConfig) async {
        for package in ["com.amoo.companion.test", "com.amoo.companion"] {
            _ = try? await Adb(context: shellContext)
                .serial(config.serial)
                .amForceStop(package: package)
                .run()
                .processResult
        }
        _ = try? await Adb(context: shellContext)
            .serial(config.serial)
            .removeForwardTCP(localPort: config.port)
            .run()
            .processResult
    }

    private func installAPKs(
        config: AndroidCompanionConfig,
        appApkPath: String,
        testApkPath: String
    ) async throws {
        for (label, apkPath) in [("app", appApkPath), ("test", testApkPath)] {
            let result: ProcessResult
            do {
                result = try await Adb(context: shellContext)
                    .serial(config.serial)
                    .install(apk: apkPath, replace: true)
                    .run()
                    .processResult
            } catch {
                throw AndroidCompanionError.installFailed(error.localizedDescription)
            }
            if result.exitCode != 0 {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                throw AndroidCompanionError.installFailed("Failed to install Android \(label) APK:\n\(message)")
            }
        }
    }

    private func forwardPort(config: AndroidCompanionConfig) async throws {
        let result: ProcessResult
        do {
            result = try await Adb(context: shellContext)
                .serial(config.serial)
                .forwardTCP(localPort: config.port, remotePort: config.port)
                .run()
                .processResult
        } catch {
            throw AndroidCompanionError.launchFailed("adb forward: \(error.localizedDescription)")
        }
        if result.exitCode != 0 {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AndroidCompanionError.launchFailed("adb forward failed: \(message)")
        }
    }

    private func launchInstrumentation(config: AndroidCompanionConfig) async throws -> any SpawnedProcess {
        let logPath = Self.launchLogPath(port: config.port)
        FileManager.default.createFile(atPath: logPath, contents: nil)

        do {
            return try await Adb(context: shellContext)
                .serial(config.serial)
                .rawArguments(Self.instrumentArguments(port: config.port))
                // The file is freshly created above; use append for both streams so SwiftyShell
                // can safely share one destination without competing overwrite handles.
                .stdout(.file(path: logPath, append: true))
                .stderr(.file(path: logPath, append: true))
                .spawn(teardown: .graceful)
        } catch {
            throw AndroidCompanionError.launchFailed(error.localizedDescription)
        }
    }

    private func isReachable(host: String, port: Int) async -> Bool {
        await isTCPPortReachable(host: host, port: port, timeoutSeconds: 1.5)
    }

    private func waitUntilReachable(host: String, port: Int, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if await isCompanionReady(host: host, port: port) {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        let logPath = Self.launchLogPath(port: port)
        if let log = try? String(contentsOfFile: logPath, encoding: .utf8), !log.isEmpty {
            print("--- android companion launch log (last 3000 chars) ---")
            print(log.suffix(3000))
            print("-----------------------------------------------------")
        }
        throw AndroidCompanionError.readyTimeout(seconds: timeoutSeconds, port: port)
    }
}

extension AndroidCompanionManager: AndroidCompanionManaging {}
