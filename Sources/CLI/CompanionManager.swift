import AmooCore
import Foundation
import Network
import ProcessRunner
import SwiftyShell
import XcodeBuildKit
import XcodeGenKit

// MARK: - Thread-safe one-shot continuation box

private final class ReachabilityBox: @unchecked Sendable {
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

// MARK: - Configuration

struct CompanionConfig {
    var host: String
    var port: Int
    var companionDir: String
    var deviceUDID: String
    var readyTimeoutSeconds: Int
    /// Bundle ID of the app under test, handed to the runner so gestures resolve to it rather
    /// than to whatever happens to be frontmost when a command arrives.
    var targetAppID: String?

    init(
        host: String = "127.0.0.1",
        port: Int = 22087,
        companionDir: String? = nil,
        deviceUDID: String,
        readyTimeoutSeconds: Int = 30,
        targetAppID: String? = nil
    ) {
        self.host = host
        self.port = port
        self.companionDir = companionDir ?? CompanionConfig.defaultCompanionDir()
        self.deviceUDID = deviceUDID
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.targetAppID = targetAppID
    }

    /// The companion lives next to the amoo installation, not next to whoever invoked it.
    ///
    /// This used to resolve against the current working directory, so every invocation from
    /// another project failed with "No project spec found at <that project>/CompanionApps/iOS" —
    /// a path the caller has no reason to have. The executable's own location is walked upward
    /// instead, with the CWD kept as a last resort for running out of a source checkout.
    static func defaultCompanionDir() -> String {
        let fileManager = FileManager.default
        var searchRoots: [URL] = []

        var executableDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            searchRoots.append(executableDir)
            executableDir.deleteLastPathComponent()
        }
        searchRoots.append(URL(fileURLWithPath: fileManager.currentDirectoryPath))

        for root in searchRoots {
            let candidate = root.appendingPathComponent("CompanionApps/iOS")
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate.path
            }
        }

        return fileManager.currentDirectoryPath + "/CompanionApps/iOS"
    }
}

// MARK: - Errors

enum CompanionError: Error, CustomStringConvertible {
    case buildFailed(String)
    case launchFailed(String)
    case readyTimeout(Int)
    case unsupportedPlatform
    case xcodegeneNotFound

    var description: String {
        switch self {
        case let .buildFailed(reason):
            "Companion build failed: \(reason)"
        case let .launchFailed(reason):
            "Companion launch failed: \(reason)"
        case let .readyTimeout(seconds):
            "Companion did not become reachable after \(seconds)s."
        case .unsupportedPlatform:
            "Companion management is only supported on macOS."
        case .xcodegeneNotFound:
            "xcodegen not found. Install it with: brew install xcodegen"
        }
    }
}

// MARK: - CompanionManager

final class CompanionManager: @unchecked Sendable {
    private var companionProcess: (any SpawnedProcess)?
    private let shellContext: ShellContext

    init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        shellContext = ShellContext(
            executor: ProcessRunnerCommandExecutor(processRunner: processRunner)
        )
    }

    /// Builds (installs) the companion test bundle without launching it.
    func install(config: CompanionConfig, force: Bool = false) async throws {
        let productsDir = config.companionDir + "/build/Build/Products"
        if !force, findXCTestRun(productsDir: productsDir) != nil {
            print(
                colored("Companion already built.", .green) + colored(" Use --force to rebuild.", .gray)
            )
            return
        }
        print("Building companion app (this may take a moment)...")
        try await withCLILoadingIndicator("Building companion app") {
            try await buildForTesting(config: config)
        }
        print(colored("Companion installed successfully.", .green))
    }

    /// Shuts down any running companion, then installs (using pre-built if available) and starts fresh.
    func reinstallAndStart(config: CompanionConfig) async throws {
        await shutdown()
        print("Rebuilding companion app (this may take a moment)...")
        try await withCLILoadingIndicator("Building companion app") {
            try await buildForTesting(config: config)
        }

        let productsDir = config.companionDir + "/build/Build/Products"
        let xctestrunPath = findXCTestRun(productsDir: productsDir)
        guard let testrun = xctestrunPath else {
            throw CompanionError.buildFailed("No .xctestrun found after build.")
        }

        print("Installing and starting companion on port \(config.port)...")
        try await launchCompanion(xctestrunPath: testrun, config: config)
        try await withCLILoadingIndicator("Waiting for companion on port \(config.port)") {
            try await waitUntilReachable(
                host: config.host,
                port: config.port,
                timeoutSeconds: config.readyTimeoutSeconds
            )
        }
        print(colored("Companion ready.", .bold, .green))
    }

    /// Ensures the companion is running. Builds and launches it if necessary.
    func ensureRunning(config: CompanionConfig) async throws {
        if await isReachable(host: config.host, port: config.port) {
            print("Companion already running on port \(config.port).")
            return
        }

        let productsDir = config.companionDir + "/build/Build/Products"
        var xctestrunPath = findXCTestRun(productsDir: productsDir)

        if xctestrunPath == nil {
            print("No build found. Building companion app (this may take a moment)...")
            try await withCLILoadingIndicator("Building companion app") {
                try await buildForTesting(config: config)
            }
            xctestrunPath = findXCTestRun(productsDir: productsDir)
        }

        guard let testrun = xctestrunPath else {
            throw CompanionError.buildFailed("No .xctestrun found after build.")
        }

        print("Starting companion on port \(config.port)...")
        try await launchCompanion(xctestrunPath: testrun, config: config)

        try await withCLILoadingIndicator("Waiting for companion on port \(config.port)") {
            try await waitUntilReachable(
                host: config.host,
                port: config.port,
                timeoutSeconds: config.readyTimeoutSeconds
            )
        }
        print(colored("Companion ready.", .bold, .green))
    }

    func shutdown() async {
        guard let process = companionProcess else { return }
        _ = await process.teardownAndWait()
        companionProcess = nil
    }

    // MARK: - Private

    private func isReachable(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ReachabilityBox(continuation: continuation)
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

    private func findXCTestRun(productsDir: String) -> String? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: productsDir),
                includingPropertiesForKeys: nil,
                options: .skipsSubdirectoryDescendants
            )
        else { return nil }

        for case let url as URL in enumerator where url.pathExtension == "xctestrun" {
            return url.path
        }
        return nil
    }

    private func buildForTesting(config: CompanionConfig) async throws {
        let genResult: ProcessResult
        do {
            genResult = try await XcodeGen(context: shellContext)
                .generate()
                .spec(config.companionDir + "/project.yml")
                .run()
                .processResult
        } catch let error as ShellError {
            if case .commandNotFound = error {
                throw CompanionError.xcodegeneNotFound
            }
            throw error
        }
        if genResult.exitCode != 0 {
            throw CompanionError.buildFailed("xcodegen failed: \(genResult.stderr)")
        }

        // Build for testing
        let buildResult = try await XcodeBuild(context: shellContext)
            .trailingArgument("build-for-testing")
            .option(.scheme("AmooCompanion"))
            .option(.destination("platform=iOS Simulator,id=\(config.deviceUDID)"))
            .option(.derivedDataPath(config.companionDir + "/build"))
            .option(.project(config.companionDir + "/AmooCompanion.xcodeproj"))
            .run()
            .processResult

        if buildResult.exitCode != 0 {
            let message = buildResult.stderr.isEmpty ? buildResult.stdout : buildResult.stderr
            throw CompanionError.buildFailed(message)
        }
    }

    private func launchCompanion(xctestrunPath: String, config: CompanionConfig) async throws {
        #if os(macOS)
        let logPath = NSTemporaryDirectory() + "companion-launch.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)

        do {
            companionProcess = try await XcodeBuild(context: shellContext)
                .trailingArgument("test-without-building")
                .option(.xctestrun(xctestrunPath))
                .option(.destination("platform=iOS Simulator,id=\(config.deviceUDID)"))
                .trailingArguments([
                    "-only-testing",
                    "AmooCompanionUITests/CompanionRunner/testRunCompanion",
                    "-test-timeouts-enabled", "NO"
                ])
                // xcodebuild does NOT forward its own environment into the test runner process:
                // only `TEST_RUNNER_`-prefixed variables cross that boundary, arriving with the
                // prefix stripped. The unprefixed pair is kept for any path that execs the runner
                // directly. This was silently broken for COMPANION_PORT too — unnoticed only
                // because the value it failed to deliver matched the runner's default.
                .env("TEST_RUNNER_COMPANION_PORT", String(config.port))
                .env("TEST_RUNNER_COMPANION_TARGET_APP", config.targetAppID ?? "")
                .env("COMPANION_PORT", String(config.port))
                .env("COMPANION_TARGET_APP", config.targetAppID ?? "")
                .stdout(.file(path: logPath, append: false))
                .stderr(.file(path: logPath, append: true))
                .spawn(teardown: .graceful)
        } catch {
            throw CompanionError.launchFailed(error.localizedDescription)
        }
        #else
        _ = xctestrunPath
        _ = config
        throw CompanionError.unsupportedPlatform
        #endif
    }

    private func waitUntilReachable(host: String, port: Int, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if await isReachable(host: host, port: port) {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let logPath = NSTemporaryDirectory() + "companion-launch.log"
        if let log = try? String(contentsOfFile: logPath, encoding: .utf8), !log.isEmpty {
            print("--- companion launch log (last 3000 chars) ---")
            print(log.suffix(3000))
            print("----------------------------------------------")
        }
        throw CompanionError.readyTimeout(timeoutSeconds)
    }
}
