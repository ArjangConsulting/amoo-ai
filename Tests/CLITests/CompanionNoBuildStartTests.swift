import AmooCore
@testable import CLI
import Foundation
import ProcessRunner
import SwiftyShell
import TestCommons
import XCTest

/// Starting a device never compiles a companion: it installs the newest existing build, warns when
/// that build is older than its sources, and fails naming `amoo companion build` when none exists.
final class CompanionNoBuildStartTests: XCTestCase {
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

    func testAStalePrebuiltAndroidCompanionIsStillUsedAndReportedStaleOnlyInACheckout() throws {
        for checkout in [true, false] {
            let scratch = try TemporaryDirectory()
            defer { try? scratch.remove() }
            let companion = try companionLayout(scratch, platform: "Android", checkout: checkout)
            try write(companion.appending(path: "prebuilt/app-debug.apk"), modified: 1)
            try write(companion.appending(path: "prebuilt/app-debug-androidTest.apk"), modified: 1)
            try write(companion.appending(path: "app/src/main/Companion.kt"), modified: 2)
            let config = AndroidCompanionConfig(companionDir: companion.path, serial: nil)
            let manager = AndroidCompanionManager()
            // Starts never build, so the only existing companion is used either way. A release archive
            // unpacks its prebuilt into fresh sources, so only a checkout's prebuilt counts as stale.
            XCTAssertTrue(manager.usesBundledAPKs(config: config), "checkout=\(checkout)")
            XCTAssertEqual(manager.isBuildStale(config: config), checkout, "checkout=\(checkout)")
            XCTAssertEqual(manager.isBuildCurrent(config: config), !checkout)
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

    func testStalePrebuiltIOSProductsAreStillUsedAndReportedStaleOnlyInACheckout() throws {
        for checkout in [true, false] {
            let scratch = try TemporaryDirectory()
            defer { try? scratch.remove() }
            let companion = try companionLayout(scratch, platform: "iOS", checkout: checkout)
            let run = "prebuilt/iphonesimulator/Products/Amoo_iphonesimulator.xctestrun"
            try write(companion.appending(path: run), modified: 1)
            try write(companion.appending(path: "Sources/CompanionServer.swift"), modified: 2)
            let config = CompanionConfig(companionDir: companion.path, deviceUDID: "sim")
            let manager = CompanionManager()
            XCTAssertTrue(manager.hasBundledProducts(config: config), "checkout=\(checkout)")
            XCTAssertEqual(manager.sourcesChanged(config: config, bundled: true), checkout, "checkout=\(checkout)")
        }
    }

    func testAStartWithNoIOSBuildFailsNamingTheBuildCommandWithoutBuilding() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let runner = MockCLIProcessRunner(results: [])
        let manager = CompanionManager(processRunner: runner)
        let config = CompanionConfig(port: 0, companionDir: scratch.url.path, deviceUDID: "sim")
        do {
            try await manager.ensureRunning(config: config)
            XCTFail("Expected a missing build error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("amoo companion build --platform ios"), "\(error)")
        }
        let commands = await runner.recordedCommands()
        XCTAssertFalse(commands.contains { $0.contains("xcodebuild") || $0.contains("xcodegen") }, "\(commands)")
    }

    func testAStartWithNoAndroidBuildFailsNamingTheBuildCommandWithoutBuilding() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let runner = MockCLIProcessRunner(results: [])
        let manager = AndroidCompanionManager(processRunner: runner)
        let config = AndroidCompanionConfig(companionDir: scratch.url.path, serial: nil)
        do {
            try await manager.prepareBuild(config: config)
            XCTFail("Expected a missing build error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("amoo companion build --platform android"), "\(error)")
        }
        let commands = await runner.recordedCommands()
        XCTAssertTrue(commands.isEmpty, "\(commands)")
    }

    func testAMakeBuiltCompanionNewerThanItsSourcesIsCurrentWithoutAFingerprint() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let companion = try companionLayout(scratch, platform: "Android", checkout: true)
        try write(companion.appending(path: "app/src/main/Companion.kt"), modified: 1)
        try write(companion.appending(path: "app/build/outputs/apk/debug/app-debug.apk"), modified: 2)
        try write(
            companion.appending(path: "app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"), modified: 2
        )
        let config = AndroidCompanionConfig(companionDir: companion.path, serial: nil)
        let manager = AndroidCompanionManager()
        XCTAssertFalse(manager.isBuildStale(config: config))
        try write(companion.appending(path: "app/src/main/Companion.kt"), modified: 3)
        XCTAssertTrue(manager.isBuildStale(config: config), "a later source edit makes it stale")
        XCTAssertTrue(manager.staleNotice(config: config).contains("amoo companion build --platform android"))
    }
}

/// `env up` says which companion build it used: source, build time, commit, staleness and, on
/// Android, whether the device already held it.
final class CompanionBuildIdentityTests: XCTestCase {
    func testTheReportCarriesTheIdentityAndTheSummaryNamesIt() throws {
        let identity = CompanionBuildIdentity(
            source: "local",
            path: "/c/app.apk",
            builtAt: "2026-11-20T12:28:00Z",
            sourceCommit: "402e1fb0123456789",
            stale: true,
            sha256: "aa",
            installedSHA256: "bb"
        )
        let report = EnvCompanionReport(phases: [], buildIdentity: identity)
        let json = try XCTUnwrap(String(bytes: JSONEncoder().encode(report), encoding: .utf8))
        XCTAssertTrue(json.contains(#""build_identity""#), json)
        XCTAssertTrue(json.contains(#""source_commit":"402e1fb0123456789""#), json)
        XCTAssertTrue(json.contains(#""installed_sha256":"bb""#), json)
        XCTAssertEqual(identity.alreadyInstalled, false)
        XCTAssertTrue(identity.summary.contains("local build, built 2026-11-20T12:28:00Z, from 402e1fb01234"))
        XCTAssertTrue(identity.summary.contains("older than its sources"))
    }

    func testTheSourceCommitIsReadFromTheBuildDirectory() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        XCTAssertNil(CompanionSourceCommit.read(directory: scratch.url.path))
        try Data("abc123-dirty\n".utf8).write(to: scratch.url.appending(path: CompanionSourceCommit.fileName))
        XCTAssertEqual(CompanionSourceCommit.read(directory: scratch.url.path), "abc123-dirty")
    }

    func testAPrebuiltAndroidIdentityComesFromThePrebuiltDirectory() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for name in ["app-debug.apk", "app-debug-androidTest.apk"] {
            let url = scratch.url.appending(path: "prebuilt/\(name)")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(name.utf8).write(to: url)
        }
        try Data("feedbeef\n".utf8).write(to: scratch.url.appending(path: "prebuilt/source-commit"))
        let manager = AndroidCompanionManager(processRunner: MockCLIProcessRunner(results: []))
        let config = AndroidCompanionConfig(companionDir: scratch.url.path, serial: nil)
        let identity = await manager.buildIdentity(config: config)
        XCTAssertEqual(identity.source, "prebuilt")
        XCTAssertEqual(identity.sourceCommit, "feedbeef")
        XCTAssertNotNil(identity.sha256)
        XCTAssertFalse(identity.stale, "no sources and no checkout: never stale")
    }
}
