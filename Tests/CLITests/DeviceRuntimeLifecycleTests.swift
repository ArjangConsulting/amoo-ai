import AmooCore
@testable import CLI
import Foundation
import MobileDevices
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DeviceRuntimeLifecycleTests: XCTestCase {
    func testHealthRequiresLiveProcessAndReachableCompanion() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var runtime = try store.start(platform: AmooCore.Platform.ios, deviceID: "SIM", deviceName: nil, owner: nil)
        let ready = DeviceRuntimeHealth(processMatches: { _, _ in true }, isReady: { _ in true })
        let quiet = DeviceRuntimeHealth(processMatches: { _, _ in true }, isReady: { _ in false })
        let dead = DeviceRuntimeHealth(processMatches: { _, _ in false }, isReady: { _ in true })
        let starting = await ready.state(of: runtime)
        XCTAssertEqual(starting, .starting)
        runtime.companionPID = 123
        runtime.port = 22093
        let running = await ready.state(of: runtime)
        XCTAssertEqual(running, .running)
        runtime.state = .running
        let unresponsive = await quiet.state(of: runtime)
        XCTAssertEqual(unresponsive, .unresponsive)
        let stale = await dead.state(of: runtime)
        XCTAssertEqual(stale, .stale)
        runtime.expiresAt = .distantPast
        let expired = await ready.state(of: runtime)
        XCTAssertEqual(expired, .running)
        runtime.state = .stopped
        let stopped = await ready.state(of: runtime)
        XCTAssertEqual(stopped, .stopped)
    }

    func testListIncludesExpiredRecordsAsStaleWithoutRemovingThem() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url, ttl: 60)
        let runtime = try store.start(
            platform: AmooCore.Platform.ios,
            deviceID: "SIM",
            deviceName: nil,
            owner: nil,
            now: Date().addingTimeInterval(-120)
        )
        let result = await runEnvList(json: true, store: store)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: [[String: Any]]]
        )
        XCTAssertEqual(object["runtimes"]?.first?["state"] as? String, "stale")
        XCTAssertTrue(result.output.contains("runtime_id"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(deviceID: runtime.deviceID).path))
    }

    func testStoppingByDeviceUsesAccessLockAndCanCleanExpiredRuntime() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url, ttl: 60)
        let runtime = try store.start(
            platform: AmooCore.Platform.ios,
            deviceID: "SIM",
            deviceName: nil,
            owner: nil,
            now: Date().addingTimeInterval(-120)
        )
        let access = try DeviceAccessLock(deviceID: runtime.deviceID, store: store)
        let refused = await runEnvDown(EnvDownOptions(deviceID: runtime.deviceID, force: true), store: store)
        XCTAssertEqual(refused.exitCode, 3)
        XCTAssertNotNil(store.runtime(id: runtime.id, includingExpired: true))
        access.release()
        let stopped = await runEnvDown(EnvDownOptions(deviceID: runtime.deviceID, json: true), store: store)
        XCTAssertEqual(stopped.exitCode, 0, stopped.output)
        XCTAssertNil(store.runtime(id: runtime.id, includingExpired: true))
        XCTAssertFalse(stopped.output.contains("lease"))
    }

    func testMigrationKeepsExpiredCompanionDiscoverableAndNormalizesStorage() async throws {
        let scratch = try makeScratchDirectory().url
        let old = DeviceClaimStore(directory: scratch.appendingPathComponent("old"), ttl: 60)
        var record = try old.acquire(
            platform: .ios,
            deviceID: "SIM",
            deviceName: "iPhone",
            now: Date().addingTimeInterval(-120)
        )
        record.port = 22093
        record.bootedByLease = true
        record = try old.renew(record, now: record.createdAt)
        let store = DeviceRuntimeStore(directory: scratch.appendingPathComponent("new"), legacyDirectory: old.directory)
        let migrated = try XCTUnwrap(store.runtime(id: record.id, includingExpired: true))
        XCTAssertEqual(migrated.id, record.id.replacingOccurrences(of: "lease-", with: "runtime-"))
        XCTAssertEqual(migrated.port, record.port)
        XCTAssertTrue(migrated.bootedByRuntime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.fileURL(deviceID: record.deviceID).path))
        let saved = try String(contentsOf: store.fileURL(deviceID: record.deviceID), encoding: .utf8)
        XCTAssertFalse(saved.lowercased().contains("lease"), saved)
        XCTAssertFalse(saved.contains("holder"), saved)
        let stopped = await runEnvDown(EnvDownOptions(runtimeID: record.id, json: true), store: store)
        XCTAssertEqual(stopped.exitCode, 0, stopped.output)
    }

    func testMigrationDefersToActiveOldSessionAndStillProtectsItsDevice() throws {
        let scratch = try makeScratchDirectory().url
        let old = DeviceClaimStore(directory: scratch.appendingPathComponent("old"))
        let record = try old.acquire(platform: .ios, deviceID: "SIM")
        let access = try DeviceSessionLock(deviceID: record.deviceID, store: old)
        defer { access.release() }
        let store = DeviceRuntimeStore(directory: scratch.appendingPathComponent("new"), legacyDirectory: old.directory)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertThrowsError(try store.start(platform: AmooCore.Platform.ios, deviceID: "SIM"))
        XCTAssertThrowsError(try DeviceAccessLock(deviceID: "SIM", store: store))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.fileURL(deviceID: record.deviceID).path))
    }

    func testOldManifestMigratesCredentialsAndOnlyWritesNewFields() throws {
        let report = EnvUpReport(ok: true, runtimeID: "runtime-1234", platform: "ios", port: 22093)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(renderJSON(report).utf8)) as? [String: Any])
        object.removeValue(forKey: "runtime_id")
        object["lease"] = "lease-1234"
        object["holder_pid"] = 123
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "ok": true, "results": [object]])
        let migrated = try InitManifest.decodeMigrating(data)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.results.first?.runtimeID, "runtime-1234")
        XCTAssertEqual(migrated.results.first?.companionPID, 123)
        let output = renderJSON(migrated)
        XCTAssertFalse(output.contains("lease"))
        XCTAssertFalse(output.contains("holder"))
    }

    func testOwnedRuntimeReuseDoesNotStartAnotherCompanion() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var runtime = try store.start(platform: AmooCore.Platform.ios, deviceID: "SIM", deviceName: nil, owner: nil)
        runtime.port = 22093
        runtime.companionPID = 123
        runtime.state = .running
        runtime = try store.refresh(runtime)
        var dependencies = EnvUpDependencies()
        dependencies.health = DeviceRuntimeHealth(processMatches: { _, _ in true }, isReady: { _ in true })
        dependencies
            .resolve = { _, _ in XCTFail("Reuse must keep the existing device"); throw EnvError.noDevice("unexpected") }
        dependencies
            .start = { _, _, _ in
                XCTFail("Reuse must not start a second process"); throw EnvError.noDevice("unexpected")
            }
        dependencies.prepare = { _, _, _ in }
        let result = await runEnvUp(
            EnvUpOptions(runtimeID: runtime.id, platform: .ios, deviceID: "SIM", json: true),
            store: store,
            dependencies: dependencies
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(store.all().count, 1)
        let decoded = try JSONDecoder().decode(EnvUpReport.self, from: Data(result.output.utf8))
        XCTAssertEqual(decoded.runtimeID, runtime.id)
        XCTAssertEqual(decoded.state, .running)
        XCTAssertTrue(decoded.humanSummary.contains("Stop: amoo env down --runtime-id \(runtime.id)"))
    }

    func testStaleRecordDoesNotCountAsRunningInDoctor() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var runtime = try store.start(
            platform: AmooCore.Platform.ios,
            deviceID: "SIM",
            deviceName: "iPhone",
            owner: nil
        )
        runtime.state = .stale
        let report = DoctorReport(
            ok: false,
            cli: .init(version: "test"),
            mcpServers: [],
            adbServerRunning: false,
            devices: [],
            companions: [],
            runtimes: [runtime],
            issues: [],
            notes: []
        )
        XCTAssertTrue(humanDoctorSummary(report).contains("amoo running on 0 devices:"))
        XCTAssertTrue(doctorIssues(report).contains { $0.contains("stale") })
    }

    func testFailedCleanupKeepsExpiredRecordAndPreventsReplacement() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url, ttl: 60, reaper: { _ in false })
        let runtime = try store.start(
            platform: .ios,
            deviceID: "SIM",
            now: Date().addingTimeInterval(-120)
        )
        XCTAssertTrue(store.reapExpired().isEmpty)
        XCTAssertNotNil(store.runtime(id: runtime.id, includingExpired: true))
        XCTAssertThrowsError(try store.start(platform: .ios, deviceID: "SIM"))
        XCTAssertEqual(store.allIncludingExpired().map(\.id), [runtime.id])
    }

    func testConcurrentStartupPublishesOnlyOneRuntime() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { (try? store.start(platform: .ios, deviceID: "SIM")) != nil }
            }
            var count = 0
            for await success in group where success {
                count += 1
            }
            return count
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(store.all().count, 1)
    }

    func testDeviceAccessIsAvailableAfterOwnerExitsScope() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        do {
            let access = try DeviceAccessLock(deviceID: "SIM", store: store)
            XCTAssertThrowsError(try DeviceAccessLock(deviceID: "SIM", store: store))
            withExtendedLifetime(access) {}
        }
        let next = try DeviceAccessLock(deviceID: "SIM", store: store)
        next.release()
    }

    func testCrashedProcessReleasesDeviceAccess() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let path = store.accessFileURL(deviceID: "SIM").appendingPathExtension("session-lock").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = """
        import fcntl, signal, sys
        device = open(sys.argv[1], 'w')
        fcntl.flock(device, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print('ready', flush=True)
        signal.pause()
        """
        process.arguments = ["python3", "-c", script, path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning {
                process.terminate(); process.waitUntilExit()
            }
        }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        XCTAssertEqual(ready, Data("ready\n".utf8))
        XCTAssertThrowsError(try DeviceAccessLock(deviceID: "SIM", store: store))
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit()
        let next = try DeviceAccessLock(deviceID: "SIM", store: store)
        next.release()
    }

    func testMigrationCanRewriteTheExistingDirectoryInPlace() throws {
        let directory = try makeScratchDirectory().url
        let old = DeviceClaimStore(directory: directory)
        let record = try old.acquire(platform: .ios, deviceID: "SIM")
        let store = DeviceRuntimeStore(directory: directory, legacyDirectory: directory)
        XCTAssertEqual(store.all().count, 1)
        let migrated = try XCTUnwrap(store.runtime(id: record.id))
        XCTAssertEqual(migrated.id, DeviceRuntimeStore.normalizedID(record.id))
        let data = try String(contentsOf: store.fileURL(deviceID: "SIM"), encoding: .utf8)
        XCTAssertFalse(data.lowercased().contains("lease"))
    }

    func testAndroidStopFailureRetainsRuntimeForRetry() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let runtime = try store.start(platform: .android, deviceID: "emulator-test")
        let failed = await runEnvDown(
            EnvDownOptions(runtimeID: runtime.id, json: true),
            store: store,
            dependencies: EnvDownDependencies(stopAndroid: { _ in false })
        )
        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertNotNil(store.runtime(id: runtime.id))
        let report = try JSONDecoder().decode(EnvDownReport.self, from: Data(failed.output.utf8))
        XCTAssertFalse(report.companionStopped)
        let retried = await runEnvDown(
            EnvDownOptions(runtimeID: runtime.id),
            store: store,
            dependencies: EnvDownDependencies(stopAndroid: { _ in true })
        )
        XCTAssertEqual(retried.exitCode, 0, retried.output)
        XCTAssertNil(store.runtime(id: runtime.id))
    }
}
