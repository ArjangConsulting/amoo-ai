import AmooCore
@testable import CLI
import Foundation
import ProcessRunner
import TestCommons
import XCTest

final class CompanionBuildReuseTests: XCTestCase {
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
