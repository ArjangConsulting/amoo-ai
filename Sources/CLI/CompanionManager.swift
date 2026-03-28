import Foundation
import MobileTestingCore
import Network
import ProcessRunner

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

struct CompanionConfig: Sendable {
    var host: String
    var port: Int
    var companionDir: String
    var deviceUDID: String
    var readyTimeoutSeconds: Int

    init(
        host: String = "127.0.0.1",
        port: Int = 22087,
        companionDir: String? = nil,
        deviceUDID: String,
        readyTimeoutSeconds: Int = 30
    ) {
        self.host = host
        self.port = port
        self.companionDir = companionDir ?? (FileManager.default.currentDirectoryPath + "/CompanionApps/iOS")
        self.deviceUDID = deviceUDID
        self.readyTimeoutSeconds = readyTimeoutSeconds
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
            return "Companion build failed: \(reason)"
        case let .launchFailed(reason):
            return "Companion launch failed: \(reason)"
        case let .readyTimeout(seconds):
            return "Companion did not become reachable after \(seconds)s."
        case .unsupportedPlatform:
            return "Companion management is only supported on macOS."
        case .xcodegeneNotFound:
            return "xcodegen not found. Install it with: brew install xcodegen"
        }
    }
}

// MARK: - CompanionManager

final class CompanionManager: @unchecked Sendable {
    #if os(macOS)
    private var companionProcess: Process?
    #endif
    private let processRunner: any ProcessRunner

    init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    // Builds (installs) the companion test bundle without launching it.
    func install(config: CompanionConfig, force: Bool = false) async throws {
        let productsDir = config.companionDir + "/build/Build/Products"
        if !force, findXCTestRun(productsDir: productsDir) != nil {
            print(colored("Companion already built.", .green) + colored(" Use --force to rebuild.", .gray))
            return
        }
        print("Building companion app (this may take a moment)...")
        try await withCLILoadingIndicator("Building companion app") {
            try await buildForTesting(config: config)
        }
        print(colored("Companion installed successfully.", .green))
    }

    // Shuts down any running companion, then installs (using pre-built if available) and starts fresh.
    func reinstallAndStart(config: CompanionConfig) async throws {
        shutdown()
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
        try launchCompanion(xctestrunPath: testrun, config: config)
        try await withCLILoadingIndicator("Waiting for companion on port \(config.port)") {
            try await waitUntilReachable(host: config.host, port: config.port, timeoutSeconds: config.readyTimeoutSeconds)
        }
        print(colored("Companion ready.", .bold, .green))
    }

    // Ensures the companion is running. Builds and launches it if necessary.
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
        try launchCompanion(xctestrunPath: testrun, config: config)

        try await withCLILoadingIndicator("Waiting for companion on port \(config.port)") {
            try await waitUntilReachable(host: config.host, port: config.port, timeoutSeconds: config.readyTimeoutSeconds)
        }
        print(colored("Companion ready.", .bold, .green))
    }

    func shutdown() {
        #if os(macOS)
        guard let process = companionProcess, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        companionProcess = nil
        #endif
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
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: productsDir),
            includingPropertiesForKeys: nil,
            options: .skipsSubdirectoryDescendants
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.pathExtension == "xctestrun" {
                return url.path
            }
        }
        return nil
    }

    private func buildForTesting(config: CompanionConfig) async throws {
        // Generate Xcode project
        let xcodegen = try await processRunner.run(["which", "xcodegen"])
        if xcodegen.exitCode != 0 {
            throw CompanionError.xcodegeneNotFound
        }

        let genResult = try await processRunner.run(
            ["xcodegen", "generate", "--spec", config.companionDir + "/project.yml"]
        )
        if genResult.exitCode != 0 {
            throw CompanionError.buildFailed("xcodegen failed: \(genResult.stderr)")
        }

        // Build for testing
        let buildResult = try await processRunner.run([
            "xcodebuild", "build-for-testing",
            "-scheme", "MobileTestingCompanion",
            "-destination", "platform=iOS Simulator,id=\(config.deviceUDID)",
            "-derivedDataPath", config.companionDir + "/build",
            "-project", config.companionDir + "/MobileTestingCompanion.xcodeproj"
        ])

        if buildResult.exitCode != 0 {
            let message = buildResult.stderr.isEmpty ? buildResult.stdout : buildResult.stderr
            throw CompanionError.buildFailed(message)
        }
    }

    private func launchCompanion(xctestrunPath: String, config: CompanionConfig) throws {
        #if os(macOS)
        let logPath = NSTemporaryDirectory() + "companion-launch.log"
        let process = makeCompanionLaunchProcess(xctestrunPath: xctestrunPath, config: config)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw CompanionError.launchFailed(error.localizedDescription)
        }

        companionProcess = process
        #else
        _ = xctestrunPath
        _ = config
        throw CompanionError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    func makeCompanionLaunchProcess(xctestrunPath: String, config: CompanionConfig) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrunPath,
            "-destination", "platform=iOS Simulator,id=\(config.deviceUDID)",
            "-only-testing", "MobileTestingCompanionUITests/CompanionRunner/testRunCompanion"
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["COMPANION_PORT": String(config.port)]
        ) { _, new in new }
        return process
    }
    #endif

    private func waitUntilReachable(host: String, port: Int, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        while Date() < deadline {
            if await isReachable(host: host, port: port) { return }
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
