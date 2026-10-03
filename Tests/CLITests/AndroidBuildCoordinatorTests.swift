@testable import CLI
import Foundation
import TestCommons
import XCTest

final class AndroidBuildCoordinatorTests: XCTestCase {
    private actor Counter {
        private(set) var started = 0
        func increment() {
            started += 1
        }
    }

    func testConcurrentBuildsForOneDirectoryRunOnce() async throws {
        let coordinator = AndroidBuildCoordinator()
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 4 {
                group.addTask {
                    try await coordinator.build(key: "companion") {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
            try await group.waitForAll()
        }
        let started = await counter.started
        XCTAssertEqual(started, 1)
    }

    func testBuildsRunAgainOnceThePreviousOneFinished() async throws {
        let coordinator = AndroidBuildCoordinator()
        let counter = Counter()
        for _ in 0 ..< 2 {
            try await coordinator.build(key: "companion") { await counter.increment() }
        }
        let started = await counter.started
        XCTAssertEqual(started, 2)
    }

    func testDifferentDirectoriesBuildIndependently() async throws {
        let coordinator = AndroidBuildCoordinator()
        let counter = Counter()
        async let first: Void = coordinator.build(key: "a") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
        }
        async let second: Void = coordinator.build(key: "b") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await (first, second)
        let started = await counter.started
        XCTAssertEqual(started, 2)
    }

    func testFailureReachesEveryJoinedCallerAndClearsTheSlot() async throws {
        struct Boom: Error {}
        let coordinator = AndroidBuildCoordinator()
        async let first: Void = coordinator.build(key: "k") {
            try await Task.sleep(for: .milliseconds(100))
            throw Boom()
        }
        async let second: Void = coordinator.build(key: "k") { throw Boom() }
        do {
            _ = try await (first, second)
            XCTFail("Expected the shared build failure")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        try await coordinator.build(key: "k") {}
    }

    func testFingerprintHashedBeforeBuildStaysStaleWhenSourcesChangeDuringIt() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let source = scratch.url.appending(path: "app/src/Main.kt")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "v1".write(to: source, atomically: true, encoding: .utf8)
        let config = AndroidCompanionConfig(companionDir: scratch.url.path, serial: nil)
        let manager = AndroidCompanionManager()

        let beforeBuild = manager.currentSourceFingerprint(config: config)
        try "v2".write(to: source, atomically: true, encoding: .utf8)
        try manager.writeSourceFingerprint(config: config, fingerprint: beforeBuild)

        XCTAssertFalse(manager.sourceFingerprintMatches(config: config))
    }
}
