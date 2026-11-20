import AmooCore
@testable import CLI
import Foundation
import ProcessRunner
import SwiftyShell
import TestCommons
import XCTest

final class CompanionBuildReuseTests: XCTestCase {
    func testImportedRecoverySourcesAndSigningInputsInvalidateCompanionCache() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let directory = scratch.url.appending(path: "CompanionApps/iOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = CompanionConfig(companionDir: directory.path, deviceUDID: "sim")
        let manager = CompanionManager()
        var previous = manager.currentSourceFingerprint(config: config)
        for path in [
            "Recovery.entitlements", "sign-simulator-products.py", "HostApp/Info.plist",
            "../../Sources/AmooCore/VoiceOverTraversal.swift"
        ] {
            let file = directory.appending(path: path).standardizedFileURL
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("changed".utf8).write(to: file)
            let changed = manager.currentSourceFingerprint(config: config)
            XCTAssertNotEqual(changed, previous, path)
            previous = changed
        }
    }

    func testOnlyHostSourcesTheCompanionCompilesInvalidateItsCache() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let directory = scratch.url.appending(path: "CompanionApps/iOS")
        let core = scratch.url.appending(path: "Sources/AmooCore")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        try "    sources:\n      - path: Sources\n      - path: ../../Sources/AmooCore/Geometry.swift\n"
            .write(to: directory.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        try Data("compiled".utf8).write(to: core.appending(path: "Geometry.swift"))
        let config = CompanionConfig(companionDir: directory.path, deviceUDID: "sim")
        let manager = CompanionManager()
        let built = manager.currentSourceFingerprint(config: config)

        try Data("host only".utf8).write(to: core.appending(path: "BuildInfo.swift"))
        XCTAssertEqual(manager.currentSourceFingerprint(config: config), built)

        try Data("changed".utf8).write(to: core.appending(path: "Geometry.swift"))
        XCTAssertNotEqual(manager.currentSourceFingerprint(config: config), built)
    }

    func testSimulatorBuildSigningIsExplicitAndPhysicalProductsAreExcluded() async throws {
        let runner = MockCLIProcessRunner(results: [.success(.init(exitCode: 0, stdout: "", stderr: ""))])
        let manager = CompanionManager(processRunner: runner)
        var config = CompanionConfig(companionDir: "/companion", deviceUDID: "sim")
        try await manager.signSimulatorProducts(config: config)
        config.isPhysicalDevice = true
        try await manager.signSimulatorProducts(config: config)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(
            commands,
            [["python3", "/companion/sign-simulator-products.py", "/companion/build/Build/Products"]]
        )
    }

    func testAutoPrefersFreshLocalCompanionOverBundledProducts() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        var config = CompanionConfig(companionDir: scratch.url.path, deviceUDID: "sim")
        let manager = CompanionManager()
        for (directory, timestamp) in [("prebuilt/iphonesimulator/Products", 1.0), ("build/Build/Products", 2.0)] {
            let products = scratch.url.appending(path: directory)
            try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            let run = products.appending(path: "Amoo_iphonesimulator.xctestrun")
            try Data().write(to: run)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: timestamp)],
                ofItemAtPath: run.path
            )
        }
        XCTAssertFalse(manager.hasBundledProducts(config: config))
        config.buildMode = .reuse
        XCTAssertTrue(manager.hasBundledProducts(config: config))
    }

    /// Lays out `CompanionApps/<platform>` the way a checkout or a release archive does: only a
    /// checkout has `Package.swift` and `.git` two levels up. Returns the companion directory.
    private func companionLayout(_ scratch: TemporaryDirectory, platform: String, checkout: Bool) throws -> URL {
        if checkout {
            try Data().write(to: scratch.url.appending(path: "Package.swift"))
            try FileManager.default.createDirectory(
                at: scratch.url.appending(path: ".git"), withIntermediateDirectories: true
            )
        }
        let companion = scratch.url.appending(path: "CompanionApps/\(platform)")
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: true)
        return companion
    }

    private func write(_ url: URL, modified timestamp: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: url.path
        )
    }

    func testACheckoutDoesNotUseAPrebuiltAndroidCompanionOlderThanItsSources() throws {
        for checkout in [true, false] {
            let scratch = try TemporaryDirectory()
            defer { try? scratch.remove() }
            let companion = try companionLayout(scratch, platform: "Android", checkout: checkout)
            try write(companion.appending(path: "prebuilt/app-debug.apk"), modified: 1)
            try write(companion.appending(path: "prebuilt/app-debug-androidTest.apk"), modified: 1)
            try write(companion.appending(path: "app/src/main/Companion.kt"), modified: 2)
            let config = AndroidCompanionConfig(companionDir: companion.path, serial: nil)
            let manager = AndroidCompanionManager()
            // A release archive unpacks its prebuilt into fresh sources, so there it must still be used.
            XCTAssertEqual(manager.usesBundledAPKs(config: config), !checkout, "checkout=\(checkout)")
            XCTAssertEqual(manager.bundledAPKsSkippedReason(config: config) != nil, checkout)
        }
    }

    func testACheckoutStillUsesAPrebuiltAndroidCompanionNewerThanItsSources() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let companion = try companionLayout(scratch, platform: "Android", checkout: true)
        try write(companion.appending(path: "app/src/main/Companion.kt"), modified: 1)
        try write(companion.appending(path: "prebuilt/app-debug.apk"), modified: 2)
        try write(companion.appending(path: "prebuilt/app-debug-androidTest.apk"), modified: 2)
        var config = AndroidCompanionConfig(companionDir: companion.path, serial: nil)
        XCTAssertTrue(AndroidCompanionManager().usesBundledAPKs(config: config))
        config.buildMode = .reuse
        try write(companion.appending(path: "app/src/main/Companion.kt"), modified: 3)
        XCTAssertTrue(AndroidCompanionManager().usesBundledAPKs(config: config), "Explicit reuse keeps the prebuilt")
    }

    func testACheckoutDoesNotUsePrebuiltIOSProductsOlderThanItsSources() throws {
        for checkout in [true, false] {
            let scratch = try TemporaryDirectory()
            defer { try? scratch.remove() }
            let companion = try companionLayout(scratch, platform: "iOS", checkout: checkout)
            let run = "prebuilt/iphonesimulator/Products/Amoo_iphonesimulator.xctestrun"
            try write(companion.appending(path: run), modified: 1)
            try write(companion.appending(path: "Sources/CompanionServer.swift"), modified: 2)
            let config = CompanionConfig(companionDir: companion.path, deviceUDID: "sim")
            XCTAssertEqual(CompanionManager().hasBundledProducts(config: config), !checkout, "checkout=\(checkout)")
        }
    }

    func testReleaseIOSProductsOverrideSourceCheckoutProducts() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        var config = CompanionConfig(companionDir: scratch.url.path, deviceUDID: "sim")
        let manager = CompanionManager()
        let bundled = scratch.url.appending(path: "prebuilt/iphonesimulator/Products")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data().write(to: bundled.appending(path: "Amoo_iphonesimulator.xctestrun"))

        XCTAssertEqual(manager.companionProductsDirectory(config: config), bundled.path)
        config.buildMode = .rebuild
        XCTAssertEqual(manager.companionProductsDirectory(config: config), scratch.url.path + "/build/Build/Products")
        config.buildMode = .reuse
        XCTAssertEqual(manager.companionProductsDirectory(config: config), bundled.path)
        config.isPhysicalDevice = true
        XCTAssertFalse(manager.hasBundledProducts(config: config))
    }

    func testReuseMissingIOSProductsFailsWithoutInvokingBuildTools() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let runner = MockCLIProcessRunner(results: [])
        let manager = CompanionManager(processRunner: runner)
        var config = CompanionConfig(port: 0, companionDir: scratch.url.path, deviceUDID: "sim")
        config.buildMode = .reuse
        do {
            try await manager.ensureRunning(config: config)
            XCTFail("Expected a missing cached build error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("No cached iOS companion"))
        }
        let commands = await runner.recordedCommands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testReuseMissingAndroidProductsFailsWithoutInvokingBuildTools() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let runner = MockCLIProcessRunner(results: [])
        let manager = AndroidCompanionManager(processRunner: runner)
        var config = AndroidCompanionConfig(companionDir: scratch.url.path, serial: nil)
        config.buildMode = .reuse
        do {
            try await manager.prepareBuild(config: config)
            XCTFail("Expected a missing cached build error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("No cached Android companion"))
        }
        let commands = await runner.recordedCommands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testAndroidAutoPrefersNewerCheckoutAPKsAndReuseRetainsPackagedProducts() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        var config = AndroidCompanionConfig(companionDir: scratch.url.path, serial: nil)
        let manager = AndroidCompanionManager()
        for (path, timestamp) in [
            ("prebuilt/app-debug.apk", 1.0), ("prebuilt/app-debug-androidTest.apk", 1.0),
            ("app/build/outputs/apk/debug/app-debug.apk", 2.0),
            ("app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk", 2.0)
        ] {
            let file = scratch.url.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: timestamp)],
                ofItemAtPath: file.path
            )
        }
        XCTAssertFalse(manager.usesBundledAPKs(config: config))
        config.buildMode = .reuse
        XCTAssertTrue(manager.usesBundledAPKs(config: config))
        config.buildMode = .rebuild
        XCTAssertFalse(manager.usesBundledAPKs(config: config))
    }

    func testBundledAndroidProductsAreReusedWithoutSourceFingerprint() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let bundled = scratch.url.appending(path: "prebuilt")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for name in ["app-debug.apk", "app-debug-androidTest.apk"] {
            try Data().write(to: bundled.appending(path: name))
        }
        let runner = MockCLIProcessRunner(results: [])
        let manager = AndroidCompanionManager(processRunner: runner)
        let config = AndroidCompanionConfig(companionDir: scratch.url.path, serial: nil)
        try await manager.prepareBuild(config: config)
        let commands = await runner.recordedCommands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testIOSCompilationStartsWhileSimulatorBootIsPending() async throws {
        #if os(macOS)
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let runner = ParallelStartupRunner()
        let manager = CompanionManager(processRunner: runner)
        var config = CompanionConfig(port: 0, companionDir: scratch.url.path, deviceUDID: "sim")
        config.bootSimulator = true
        do {
            try await manager.ensureRunning(config: config)
            XCTFail("The fake build deliberately fails")
        } catch {
            let overlapped = await runner.buildObservedPendingBoot
            XCTAssertTrue(overlapped, "Build should start before simulator boot finishes")
        }
        #else
        throw XCTSkip("iOS companion compilation requires macOS")
        #endif
    }

    func testSimulatorBootUsesInjectedRunnerAndWaitsForBootStatus() async throws {
        let runner = MockCLIProcessRunner(results: [
            .success(ProcessResult(exitCode: 149, stdout: "", stderr: "current state: Booted")),
            .success(ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        ])
        let manager = CompanionManager(processRunner: runner)
        var config = CompanionConfig(deviceUDID: "sim-123")
        config.bootSimulator = true
        try await manager.prepareSimulator(config: config)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [
            ["xcrun", "simctl", "boot", "sim-123"],
            ["xcrun", "simctl", "bootstatus", "sim-123", "-b"]
        ])
    }

    func testAlreadyBootedSimulatorHandlesTypedProcessExitFailure() async throws {
        let runner = MockCLIProcessRunner(results: [
            .failure(ShellError.exitFailure(
                command: "xcrun simctl boot sim-123",
                output: ShellOutput(stdout: "", stderr: "Unable to boot device in current state: Booted", exitCode: 405)
            )),
            .success(ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        ])
        let manager = CompanionManager(processRunner: runner)
        var config = CompanionConfig(deviceUDID: "sim-123")
        config.bootSimulator = true
        try await manager.prepareSimulator(config: config)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.last, ["xcrun", "simctl", "bootstatus", "sim-123", "-b"])
    }

    func testSimulatorBootFailureDoesNotProceedToReadiness() async {
        let runner = MockCLIProcessRunner(results: [
            .failure(ShellError.exitFailure(
                command: "xcrun simctl boot sim-123",
                output: ShellOutput(stdout: "", stderr: "Runtime unavailable", exitCode: 1)
            ))
        ])
        let manager = CompanionManager(processRunner: runner)
        var config = CompanionConfig(deviceUDID: "sim-123")
        config.bootSimulator = true
        do {
            try await manager.prepareSimulator(config: config)
            XCTFail("An actual boot failure must remain a failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Runtime unavailable"))
        }
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.count, 1)
    }
}

private actor ParallelStartupRunner: ProcessRunner {
    private var bootStarted = false
    private(set) var buildObservedPendingBoot = false

    func run(_ arguments: [String]) async throws -> ProcessResult {
        if arguments.contains("boot") {
            bootStarted = true
            try await Task.sleep(for: .seconds(20))
        }
        if arguments.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "xcodegen" {
            buildObservedPendingBoot = try await waitUntil(
                timeout: .seconds(2),
                pollInterval: .milliseconds(10),
                operation: { await self.bootHasStarted() },
                matching: { $0 }
            )
            return ProcessResult(exitCode: 1, stdout: "", stderr: "Deliberate test build failure")
        }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    private func bootHasStarted() -> Bool {
        bootStarted
    }
}
