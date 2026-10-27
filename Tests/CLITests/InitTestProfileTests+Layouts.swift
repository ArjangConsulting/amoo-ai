@testable import CLI
import Foundation
import StudioProtocol
import TestCommons
import XCTest

extension InitTestProfileTests {
    func testSubmoduleProfileDiscoveryStopsAtSuperprojectGitDirectory() throws {
        let scratch = try makeScratchDirectory()
        let root = scratch.url.appendingPathComponent("mobile")
        let ios = root.appendingPathComponent("iOS")
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try Data("gitdir: ../.git/modules/iOS".utf8).write(to: ios.appendingPathComponent(".git"))
        let profile = root.appendingPathComponent("amoo.md")
        let text = "```amoo-context\n{\"targetPlatform\":\"ios\",\"baseClass\":\"RootTests\"}\n```\n"
        try text.write(to: profile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try RepositoryTestProfile.discover(from: ios, platform: .ios)?.baseClass, "RootTests")
        try FileManager.default.removeItem(at: profile)
        try text.write(to: scratch.url.appendingPathComponent("amoo.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(try RepositoryTestProfile.discover(from: ios, platform: .ios))
        XCTAssertNil(try RepositoryTestProfile.discover(from: root, platform: .ios))
    }

    func testTargetDirectoryIsRelativeToOrchestratorAndDiscoveryOverridesRequestedPlatform() throws {
        let root = try makeScratchDirectory().url
        let target = root.appendingPathComponent("iOS/NovaUITests")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try """
        import XCTest
        class NovaTests: XCTestCase {
            let app = XCUIApplication()
        }
        """.write(to: target.appendingPathComponent("NovaTests.swift"), atomically: true, encoding: .utf8)
        try saveInitTestProfile(at: root, platform: .android)
        let profile = root.appendingPathComponent("amoo.md")
        XCTAssertTrue(try String(contentsOf: profile, encoding: .utf8).contains("Target directory: iOS/NovaUITests"))
        XCTAssertEqual(try RepositoryTestProfile.load(profile).targetPlatform, .ios)
    }

    func testLinkedWorktreeIsItsOwnRepositoryBoundary() throws {
        let scratch = try makeScratchDirectory()
        let worktree = scratch.url.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /repo/.git/worktrees/worktree".utf8).write(to: worktree.appendingPathComponent(".git"))
        try "```amoo-context\n{\"targetPlatform\":\"ios\",\"baseClass\":\"Parent\"}\n```\n"
            .write(to: scratch.url.appendingPathComponent("amoo.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(try RepositoryTestProfile.discover(from: worktree, platform: .ios))
    }

    func testUndiscoveredProfileUsesRequestedPlatformAndUnspecifiedProfileStaysUnscoped() throws {
        let android = try makeScratchDirectory().url
        try saveInitTestProfile(at: android, platform: .android)
        XCTAssertEqual(
            try RepositoryTestProfile.load(android.appendingPathComponent("amoo.md")).targetPlatform,
            .android
        )
        let unknown = try makeScratchDirectory().url
        try saveInitTestProfile(at: unknown)
        XCTAssertNil(try RepositoryTestProfile.load(unknown.appendingPathComponent("amoo.md")).targetPlatform)
    }

    func testHarnessScanSkipsDependenciesSymlinksAndEnforcesBudgets() throws {
        let root = try makeScratchDirectory().url
        let source = "import XCTest\nclass Tests: XCTestCase { let app = XCUIApplication() }"
        for path in ["node_modules/Hidden.swift", "iOS/UITests/Real.swift"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try source.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.swift"),
            withDestinationURL: root.appendingPathComponent("iOS/UITests/Real.swift")
        )
        XCTAssertEqual(inspectInitHarness(at: root).uiTestFiles, ["iOS/UITests/Real.swift"])
        XCTAssertTrue(inspectInitHarness(at: root, maximumEntries: 0).uiTestFiles.isEmpty)
        XCTAssertFalse(inspectInitHarness(at: root, maximumEntries: 0).diagnostics.isEmpty)
        XCTAssertTrue(inspectInitHarness(at: root, maximumFiles: 0).uiTestFiles.isEmpty)
        XCTAssertTrue(inspectInitHarness(at: root, maximumDepth: 1).uiTestFiles.isEmpty)
        XCTAssertTrue(inspectInitHarness(at: root, maximumTotalBytes: 1).uiTestFiles.isEmpty)
    }
}
