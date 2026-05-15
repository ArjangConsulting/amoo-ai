import Foundation
import GradleKit
import MobileTestingCore
import Network
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
        self.companionDir =
            companionDir ?? (FileManager.default.currentDirectoryPath + "/CompanionApps/Android")
        self.serial = (serial?.isEmpty == false && serial != "booted") ? serial : nil
        self.readyTimeoutSeconds = readyTimeoutSeconds
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
        shellContext = ShellContext(
            executor: ProcessRunnerCommandExecutor(processRunner: processRunner)
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
    func ensureRunning(config: AndroidCompanionConfig) async throws {
        // Reuse only when the same device + port are already wired up. A
        // different serial means the existing port forward is routing to the
        // wrong device — tear it down before rebuilding.
        if let active = activeConfig,
           active.serial == config.serial,
           active.port == config.port,
           await isReachable(host: config.host, port: config.port) {
            print("Android companion already running on port \(config.port) for"
                + " \(config.serial ?? "default device").")
            return
        }

        if let active = activeConfig, active.serial != config.serial || active.port != config.port {
            print("Switching Android companion from"
                + " \(active.serial ?? "default") → \(config.serial ?? "default")...")
            await shutdown()
        }

        let (appApk, testApk) = apkPaths(companionDir: config.companionDir)
        let needsBuild =
            !FileManager.default.fileExists(atPath: appApk)
                || !FileManager.default.fileExists(atPath: testApk)

        if needsBuild {
            print("No Android companion build found. Building (this may take a moment)...")
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
            .amForceStop(package: "com.manman.companion.test")
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
                    "-e", "class", "com.manman.companion.CompanionRunner",
                    "com.manman.companion.test/androidx.test.runner.AndroidJUnitRunner"
                ])
                .stdout(.file(path: logPath, append: false))
                .stderr(.file(path: logPath, append: true))
                .spawn(teardown: .graceful)
        } catch {
            throw AndroidCompanionError.launchFailed(error.localizedDescription)
        }
    }

    private func isReachable(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = AndroidReachabilityBox(continuation: continuation)
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    box.resolve(true)
                case .failed, .cancelled:
                    box.resolve(false)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                connection.cancel()
                box.resolve(false)
            }
        }
    }

    private func waitUntilReachable(host: String, port: Int, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if await isReachable(host: host, port: port) { return }
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

// MARK: - Thread-safe continuation box (separate from CompanionManager's to avoid type leak)

private final class AndroidReachabilityBox: @unchecked Sendable {
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var resolved = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return }
        resolved = true
        continuation.resume(returning: value)
    }
}
