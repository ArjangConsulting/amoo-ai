import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import XcodeBuildKit
import XcodeGenKit

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
        self.companionDir = companionDir ?? Self.defaultCompanionDir()
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
            let candidate = root.appendingPathComponent("CompanionApps/iOS")
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate.path
            }
        }

        return currentDirectoryPath + "/CompanionApps/iOS"
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
        if !force,
           findXCTestRun(productsDir: productsDir) != nil,
           sourceFingerprintMatches(config: config) {
            // Says "built", never "installed" or "running" — a previous build product on disk is
            // all this proves. Reporting it as plain success is what made a dead companion look
            // like a healthy one: nothing was on the device and nothing was listening on the port.
            print(
                colored("Companion already built.", .green)
                    + colored(" Use --force to rebuild.", .gray)
            )
            print(
                colored(
                    "This does not start it — run 'amoo companion start' to bring it up.",
                    .gray
                )
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
    func ensureRunning(config: CompanionConfig, force: Bool = false) async throws {
        if force {
            await shutdown()
        }
        let sourcesChanged = !sourceFingerprintMatches(config: config)
        if await isReachable(host: config.host, port: config.port), !force, !sourcesChanged {
            print("Companion already running on port \(config.port).")
            return
        }

        if await isReachable(host: config.host, port: config.port) {
            // `shutdown()` only reaches a runner this process spawned. A companion started by a
            // separate `amoo companion start` still owns the port, and relaunching on top of it
            // would leave the caller talking to the stale build.
            let retryHint = force
                ? "Stop that process (Ctrl-C in its terminal) and retry."
                : "Stop its 'amoo companion start' process, then retry with --force."
            throw CompanionError.launchFailed(
                "Port \(config.port) is owned by another companion process. \(retryHint)"
            )
        }

        let productsDir = config.companionDir + "/build/Build/Products"
        var xctestrunPath = findXCTestRun(productsDir: productsDir)

        if force || sourcesChanged || xctestrunPath == nil {
            print("Companion sources changed or no build exists. Building (this may take a moment)...")
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
        await isTCPPortReachable(host: host, port: port, timeoutSeconds: 1.5)
    }

    private func findXCTestRun(productsDir: String) -> String? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: productsDir),
                includingPropertiesForKeys: nil,
                options: .skipsSubdirectoryDescendants
            )
        else { return nil }

        let candidates = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "xctestrun" else { return nil }
            return url
        }
        return candidates.max(by: { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return left < right
        })?.path
    }

    private func buildForTesting(config: CompanionConfig) async throws {
        #if os(macOS)
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
        try writeSourceFingerprint(config: config)
        #else
        _ = config
        throw CompanionError.unsupportedPlatform
        #endif
    }

    func currentSourceFingerprint(config: CompanionConfig) -> String {
        let root = URL(fileURLWithPath: config.companionDir)
        let locations = [
            root.appendingPathComponent("project.yml"),
            root.appendingPathComponent("Sources", isDirectory: true),
            root.appendingPathComponent("../../Protos", isDirectory: true).standardizedFileURL
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

    private func sourceFingerprintMatches(config: CompanionConfig) -> Bool {
        let path = fingerprintPath(config: config)
        return (try? String(contentsOfFile: path, encoding: .utf8)) == currentSourceFingerprint(config: config)
    }

    private func writeSourceFingerprint(config: CompanionConfig) throws {
        let path = fingerprintPath(config: config)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try currentSourceFingerprint(config: config).write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func fingerprintPath(config: CompanionConfig) -> String {
        config.companionDir + "/build/.amoo-source-fingerprint"
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
