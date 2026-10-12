import AmooCore
@testable import CLI
import Foundation
import TestCommons
import XCTest

/// `companion status` and `companion start` agree about when a build is stale, and
/// `companion start --detach` returns once the companion is ready.
final class CompanionStaleAndDetachTests: XCTestCase {
    // MARK: - stale status

    func testBuiltRecordWithChangedSourcesReportsStaleInsteadOfBuilt() async throws {
        let dir = try makeTemporaryDirectory()
        let store = CompanionStatusStore(companionDir: dir)
        store.write(warmRecord(.built, platform: "ios", device: "booted", port: 59998, detail: nil))

        let stale = await companionStatusResult(
            platform: "ios", host: "127.0.0.1", port: 59998, store: store, isBuildCurrent: { false }
        )
        XCTAssertTrue(stale.output.contains("companion status: stale"), stale.output)
        XCTAssertTrue(stale.output.contains("rebuilds"), stale.output)
        XCTAssertEqual(stale.exitCode, 1)

        let current = await companionStatusResult(
            platform: "ios", host: "127.0.0.1", port: 59998, store: store, isBuildCurrent: { true }
        )
        XCTAssertTrue(current.output.contains("companion status: built"), current.output)
        XCTAssertEqual(current.exitCode, 1)
    }

    func testStalenessOnlyRewritesTheBuiltPhase() async throws {
        let dir = try makeTemporaryDirectory()
        let store = CompanionStatusStore(companionDir: dir)
        for phase in [CompanionPhase.building, .failed] {
            store.write(warmRecord(phase, platform: "ios", device: "booted", port: 59998, detail: "x"))
            let result = await companionStatusResult(
                platform: "ios", host: "127.0.0.1", port: 59998, store: store, isBuildCurrent: { false }
            )
            XCTAssertTrue(result.output.contains(phase.rawValue), result.output)
            XCTAssertFalse(result.output.contains("stale"), result.output)
        }
    }

    /// The shared predicate: status and start decide from the same answer.
    func testIOSBuildIsCurrentOnlyWithProductsAndMatchingSources() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let config = CompanionConfig(companionDir: scratch.url.path, deviceUDID: "sim")
        let manager = CompanionManager()
        XCTAssertFalse(manager.isBuildCurrent(config: config), "no products yet")

        let products = scratch.url.appending(path: "build/Build/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try Data().write(to: products.appending(path: "Amoo_iphonesimulator.xctestrun"))
        XCTAssertFalse(manager.isBuildCurrent(config: config), "products exist but no fingerprint was recorded")

        try manager.writeSourceFingerprint(config: config)
        XCTAssertTrue(manager.isBuildCurrent(config: config))
        XCTAssertFalse(manager.sourcesChanged(config: config, bundled: false))

        try Data("changed".utf8).write(to: scratch.url.appending(path: "Recovery.entitlements"))
        XCTAssertFalse(manager.isBuildCurrent(config: config), "a source edit makes the build stale")
        XCTAssertTrue(manager.sourcesChanged(config: config, bundled: false))

        var rebuild = config
        rebuild.buildMode = .rebuild
        XCTAssertTrue(manager.sourcesChanged(config: rebuild, bundled: true))
    }

    func testAndroidBuildIsCurrentOnlyWithAPKsAndMatchingSources() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let config = AndroidCompanionConfig(companionDir: scratch.url.path, serial: nil)
        let manager = AndroidCompanionManager()
        XCTAssertFalse(manager.isBuildCurrent(config: config))

        let paths = manager.apkPaths(companionDir: scratch.url.path, useBundled: true)
        for path in [paths.app, paths.test] {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: URL(fileURLWithPath: path))
        }
        XCTAssertFalse(manager.isBuildCurrent(config: config), "APKs exist but no fingerprint was recorded")
        try manager.writeSourceFingerprint(config: config)
        XCTAssertTrue(manager.isBuildCurrent(config: config))
        var rebuild = config
        rebuild.buildMode = .rebuild
        XCTAssertFalse(manager.isBuildCurrent(config: rebuild))
    }

    // MARK: - --detach

    func testDetachFlagParsesOnlyWhenGiven() {
        guard case let .success(plain) = parseCompanionCommandOptions(args: ["start"]),
              case let .success(detached) = parseCompanionCommandOptions(args: ["start", "--detach", "--port", "23001"])
        else { return XCTFail("Expected parser success") }
        XCTAssertFalse(plain.detach)
        XCTAssertTrue(detached.detach)
        XCTAssertEqual(detached.port, 23001)
    }

    func testHelpDocumentsDetach() {
        XCTAssertTrue(renderCompanionHelp().contains("--detach"))
    }

    func testDetachedHolderRunsTheSameStartWithoutDetachAndWithExplicitPortAndTimeout() {
        var options = parsedStart(["start", "--device", "UDID-1", "--app", "com.example", "--force"])
        options.companionDir = "/companion"
        let arguments = detachedCompanionStartArguments(
            options: options, executable: "/bin/amoo", port: 23001, readyTimeoutSeconds: 300
        )
        XCTAssertEqual(arguments, [
            "/bin/amoo", "companion", "start", "--platform", "ios", "--device", "UDID-1",
            "--port", "23001", "--ready-timeout", "300", "--app", "com.example",
            "--companion-dir", "/companion", "--force"
        ])
        XCTAssertFalse(arguments.contains("--detach"), "the holder must stay in the foreground of its own session")
    }

    func testDetachReturnsPidPortAndStopHintOnceReady() async {
        let spawned = Locked<[String]>([])
        let polls = Locked(0)
        let hooks = hooks(
            spawn: { arguments, _ in
                spawned.set(arguments)
                return 4242
            },
            isReady: { _ in polls.increment() >= 3 }
        )
        let result = await runDetachedCompanionStart(
            options: parsedStart(["start", "--port", "23001", "--ready-timeout", "30"]), hooks: hooks
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("port 23001"), result.output)
        XCTAssertTrue(result.output.contains("pid 4242"), result.output)
        XCTAssertTrue(result.output.contains("kill 4242"), result.output)
        XCTAssertEqual(spawned.get().prefix(3), ["/bin/amoo", "companion", "start"])
        XCTAssertEqual(polls.get(), 3)
    }

    func testDetachFailsWithTheLogTailWhenTheHolderDiesBeforeReady() async throws {
        let log = NSTemporaryDirectory() + "amoo-companion-ios-23002.log"
        try Data("boom: build failed".utf8).write(to: URL(fileURLWithPath: log))
        defer { try? FileManager.default.removeItem(atPath: log) }
        let hooks = hooks(spawn: { _, _ in 4243 }, isReady: { _ in false }, isAlive: { _ in false })
        let result = await runDetachedCompanionStart(
            options: parsedStart(["start", "--port", "23002"]), hooks: hooks
        )
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("exited before becoming ready"), result.output)
        XCTAssertTrue(result.output.contains("boom: build failed"), result.output)
    }

    func testDetachStopsTheHolderAndFailsWhenItNeverBecomesReady() async {
        let stopped = Locked<Int32?>(nil)
        let hooks = hooks(
            spawn: { _, _ in 4244 }, isReady: { _ in false }, stop: { stopped.set($0) }, buildSlackSeconds: 0
        )
        let result = await runDetachedCompanionStart(
            options: parsedStart(["start", "--port", "23003", "--ready-timeout", "1"]), hooks: hooks
        )
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("did not become ready on port 23003"), result.output)
        XCTAssertEqual(stopped.get(), 4244)
    }

    func testDetachReportsASpawnFailureAndAMissingExecutable() async {
        struct SpawnError: Error {}
        let failing = hooks(spawn: { _, _ in throw SpawnError() })
        let spawnFailure = await runDetachedCompanionStart(options: parsedStart(["start"]), hooks: failing)
        XCTAssertEqual(spawnFailure.exitCode, 1)
        XCTAssertTrue(spawnFailure.output.contains("Companion start failed"), spawnFailure.output)

        var noExecutable = hooks()
        noExecutable.executablePath = { nil }
        let missing = await runDetachedCompanionStart(options: parsedStart(["start"]), hooks: noExecutable)
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.output.contains("Cannot locate the amoo executable"), missing.output)
    }

    // MARK: - helpers

    private func parsedStart(_ args: [String]) -> CompanionCommandOptions {
        guard case let .success(options) = parseCompanionCommandOptions(args: args) else {
            preconditionFailure("unparseable test arguments \(args)")
        }
        return options
    }

    private func hooks(
        spawn: @escaping @Sendable ([String], String) async throws -> Int32 = { _, _ in 1 },
        isReady: @escaping @Sendable (Int) async -> Bool = { _ in true },
        isAlive: @escaping @Sendable (Int32) -> Bool = { _ in true },
        stop: @escaping @Sendable (Int32) -> Void = { _ in },
        buildSlackSeconds: Int = 600
    ) -> DetachedCompanionHooks {
        DetachedCompanionHooks(
            executablePath: { "/bin/amoo" },
            spawn: spawn,
            isReady: isReady,
            isAlive: isAlive,
            stop: stop,
            pollInterval: .milliseconds(1),
            buildSlackSeconds: buildSlackSeconds
        )
    }
}

/// Minimal lock-protected box for values mutated from `@Sendable` test hooks.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}

private extension Locked where Value == Int {
    /// Adds one and returns the new count.
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
