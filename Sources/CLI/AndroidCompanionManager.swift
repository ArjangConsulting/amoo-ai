import AmooCore
import Foundation
import GradleKit
import ProcessRunner
import SwiftyShell

// MARK: - Configuration

struct AndroidCompanionConfig {
    var host: String
    var port: Int
    var companionDir: String
    var serial: String?
    var readyTimeoutSeconds: Int

    init(
        host: String = "127.0.0.1",
        port: Int = 22088,
        companionDir: String? = nil,
        serial: String?,
        readyTimeoutSeconds: Int = 60
    ) {
        self.host = host
        self.port = port
        self.companionDir = companionDir ?? Self.defaultCompanionDir()
        self.serial = (serial?.isEmpty == false && serial != "booted") ? serial : nil
        self.readyTimeoutSeconds = readyTimeoutSeconds
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
    case readyTimeout(Int)

    var description: String {
        switch self {
        case let .buildFailed(reason):
            "Android companion build failed: \(reason)"
        case let .installFailed(reason):
            "Android companion install failed: \(reason)"
        case let .launchFailed(reason):
            "Android companion launch failed: \(reason)"
        case let .readyTimeout(seconds):
            "Android companion did not become reachable after \(seconds)s."
        }
    }
}

// MARK: - AndroidCompanionManager

/// Host-side lifecycle for the Android companion: build (Gradle), install
/// app + test APKs, forward TCP, spawn the instrumentation runner, wait for
/// reachability, and tear everything down on shutdown.
final class AndroidCompanionManager: @unchecked Sendable {
    private var instrumentProcess: (any SpawnedProcess)?
    private var activeConfig: AndroidCompanionConfig?
    private let shellContext: ShellContext

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
        let (appApk, testApk) = apkPaths(companionDir: config.companionDir)
        let needsBuild = force
            || !FileManager.default.fileExists(atPath: appApk)
            || !FileManager.default.fileExists(atPath: testApk)

        if needsBuild {
            print("Building Android companion (this may take a moment)...")
            try await withCLILoadingIndicator("Building Android companion") {
                try await self.buildAPKs(config: config)
            }
        } else {
            print(colored("Android companion already built.", .green) + colored(" Use --force to rebuild.", .gray))
        }

        print("Installing Android companion APKs...")
        try await withCLILoadingIndicator("Installing Android companion APKs") {
            try await self.installAPKs(config: config, appApkPath: appApk, testApkPath: testApk)
        }
        print(colored("Android companion installed successfully.", .green))
    }

    /// Ensures the companion is reachable. Builds, installs, forwards TCP, spawns
    /// the instrumentation runner, and waits for the gRPC port — only as needed.
    func ensureRunning(config: AndroidCompanionConfig, force: Bool = false) async throws {
        let sourcesChanged = !sourceFingerprintMatches(config: config)
        if force {
            if activeConfig == nil {
                await stopExternalCompanion(config: config)
            } else {
                await shutdown()
            }
        }

        if await isReachable(host: config.host, port: config.port), !force, !sourcesChanged {
            print("Android companion already running on port \(config.port) for"
                + " \(config.serial ?? "default device").")
            return
        }

        if await isReachable(host: config.host, port: config.port), sourcesChanged {
            // The stale companion may be one we spawned. Going through `shutdown()` in that case
            // also clears `activeConfig` and drops the runner handle — otherwise the next call
            // reuses a config describing a process that is no longer serving.
            if activeConfig == nil {
                await stopExternalCompanion(config: config)
            } else {
                await shutdown()
            }
        }
        if let active = activeConfig, active.serial != config.serial || active.port != config.port {
            print("Switching Android companion from"
                + " \(active.serial ?? "default") → \(config.serial ?? "default")...")
            await shutdown()
        }

        let (appApk, testApk) = apkPaths(companionDir: config.companionDir)
        let needsBuild = force
            || sourcesChanged
            || !FileManager.default.fileExists(atPath: appApk)
            || !FileManager.default.fileExists(atPath: testApk)

        if needsBuild {
            print("Android companion sources changed or no build exists."
                + " Building (this may take a moment)...")
            try await withCLILoadingIndicator("Building Android companion") {
                try await self.buildAPKs(config: config)
            }
        }

        print("Installing Android companion APKs...")
        try await withCLILoadingIndicator("Installing Android companion APKs") {
            try await self.installAPKs(config: config, appApkPath: appApk, testApkPath: testApk)
        }

        print("Forwarding 127.0.0.1:\(config.port) → device:\(config.port)...")
        try await forwardPort(config: config)

        print("Starting Android companion instrumentation on port \(config.port)...")
        try await launchInstrumentation(config: config)
        activeConfig = config

        try await withCLILoadingIndicator("Waiting for Android companion on port \(config.port)") {
            try await self.waitUntilReachable(
                host: config.host,
                port: config.port,
                timeoutSeconds: config.readyTimeoutSeconds
            )
        }
        print(colored("Android companion ready.", .bold, .green))
    }

    func shutdown() async {
        if let process = instrumentProcess {
            _ = await process.teardownAndWait()
            instrumentProcess = nil
        }

        guard let config = activeConfig else { return }
        activeConfig = nil

        _ = try? await Adb(context: shellContext)
            .serial(config.serial)
            .amForceStop(package: "com.amoo.companion.test")
            .run()
            .processResult
        _ = try? await Adb(context: shellContext)
            .serial(config.serial)
            .removeForwardTCP(localPort: config.port)
            .run()
            .processResult
    }

    // MARK: - Private

    private func apkPaths(companionDir: String) -> (app: String, test: String) {
        let app = companionDir + "/app/build/outputs/apk/debug/app-debug.apk"
        let test = companionDir + "/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
        return (app, test)
    }

    private func buildAPKs(config: AndroidCompanionConfig) async throws {
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
        try writeSourceFingerprint(config: config)
    }

    private func stopExternalCompanion(config: AndroidCompanionConfig) async {
        _ = try? await Adb(context: shellContext)
            .serial(config.serial)
            .amForceStop(package: "com.amoo.companion.test")
            .run()
            .processResult
        _ = try? await Adb(context: shellContext)
            .serial(config.serial)
            .removeForwardTCP(localPort: config.port)
            .run()
            .processResult
    }

    func currentSourceFingerprint(config: AndroidCompanionConfig) -> String {
        let root = URL(fileURLWithPath: config.companionDir)
        let locations = [
            root.appendingPathComponent("app/src", isDirectory: true),
            root.appendingPathComponent("app/build.gradle.kts"),
            root.appendingPathComponent("build.gradle.kts"),
            root.appendingPathComponent("settings.gradle.kts")
        ]
        var hash: UInt64 = 14_695_981_039_346_656_037
        for url in sourceFiles(at: locations).sorted(by: { $0.path < $1.path }) {
            for byte in url.path.utf8 {
                hash = fingerprint(hash, byte: byte)
            }
            if let data = try? Data(contentsOf: url) {
                for byte in data {
                    hash = fingerprint(hash, byte: byte)
                }
            }
        }
        return String(hash, radix: 16)
    }

    private func sourceFiles(at locations: [URL]) -> [URL] {
        locations.flatMap { location -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else { return [] }
            if !isDirectory.boolValue {
                return [location]
            }
            guard let enumerator = FileManager.default.enumerator(
                at: location,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { item in
                guard let url = item as? URL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return nil }
                return url
            }
        }
    }

    private func fingerprint(_ hash: UInt64, byte: UInt8) -> UInt64 {
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }

    private func sourceFingerprintMatches(config: AndroidCompanionConfig) -> Bool {
        (try? String(contentsOfFile: fingerprintPath(config: config), encoding: .utf8))
            == currentSourceFingerprint(config: config)
    }

    private func writeSourceFingerprint(config: AndroidCompanionConfig) throws {
        let path = fingerprintPath(config: config)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try currentSourceFingerprint(config: config).write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func fingerprintPath(config: AndroidCompanionConfig) -> String {
        config.companionDir + "/app/build/.amoo-source-fingerprint"
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

    private func launchInstrumentation(config: AndroidCompanionConfig) async throws {
        let logPath = NSTemporaryDirectory() + "companion-android-launch.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)

        do {
            instrumentProcess = try await Adb(context: shellContext)
                .serial(config.serial)
                .rawArguments([
                    "shell", "am", "instrument",
                    "-w",
                    "-e", "class", "com.amoo.companion.CompanionRunner",
                    "com.amoo.companion.test/androidx.test.runner.AndroidJUnitRunner"
                ])
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
            if await isReachable(host: host, port: port) {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        let logPath = NSTemporaryDirectory() + "companion-android-launch.log"
        if let log = try? String(contentsOfFile: logPath, encoding: .utf8), !log.isEmpty {
            print("--- android companion launch log (last 3000 chars) ---")
            print(log.suffix(3000))
            print("-----------------------------------------------------")
        }
        throw AndroidCompanionError.readyTimeout(timeoutSeconds)
    }
}
