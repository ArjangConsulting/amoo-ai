// swiftlint:disable multiline_arguments
import AmooCore
@testable import CLI
import Foundation
import XCTest

/// `env up` only watched the companion's port, so a 14s warm start and a 57s rebuild looked the
/// same from outside. It now reports where the time went and what the companion start reused.
final class EnvUpTimingsTests: XCTestCase {
    func testReportsStageTimingsAndTheCompanionPhasesTheChildRecorded() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var dependencies = EnvUpDependencies()
        dependencies.resolve = { _, _ in
            EnvDeviceReport(id: "SIM", name: "iPhone", os: "iOS 27.2", avd: nil, bootedByEnv: false)
        }
        dependencies.start = { _, runtime, store in
            let child = CompanionStartPhases(path: store.companionPhasesURL(runtimeID: runtime.id).path)
            child.record("check", outcome: "unchanged", since: .now)
            child.record("build", outcome: "cached", since: .now)
            child.record("launch", outcome: "launched", since: .now)
            var running = runtime
            running.port = 22093
            running.state = .running
            return try store.refresh(running)
        }
        dependencies.prepare = { _, _, app in
            app?.installed = true
        }
        let options = EnvUpOptions(platform: .ios, deviceID: "SIM", appPath: "/fixture/App.app", json: true)

        let result = await runEnvUp(options, store: store, dependencies: dependencies)

        XCTAssertEqual(result.exitCode, 0, result.output)
        let report = try JSONDecoder().decode(EnvUpReport.self, from: Data(result.output.utf8))
        let timings = try XCTUnwrap(report.timings)
        XCTAssertNotNil(timings.device)
        XCTAssertNotNil(timings.companion)
        XCTAssertNotNil(timings.app)
        XCTAssertGreaterThanOrEqual(timings.total, timings.companion ?? 0)
        XCTAssertEqual(report.companion?.build, "cached")
        XCTAssertEqual(report.companion?.runner, "launched")
        XCTAssertNil(report.companion?.install)
        XCTAssertEqual(report.companion?.phases.map(\.name), ["check", "build", "launch"])
        let runtimeID = try XCTUnwrap(report.runtimeID)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.companionPhasesURL(runtimeID: runtimeID).path),
            "the report carries the phases; the file is consumed"
        )
        XCTAssertTrue(result.output.contains("\"timings_ms\""), result.output)
    }

    func testNoAppMeansNoAppTiming() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var dependencies = EnvUpDependencies()
        dependencies.resolve = { _, _ in
            EnvDeviceReport(id: "emulator-5556", name: nil, os: nil, avd: nil, bootedByEnv: false)
        }
        dependencies.start = { _, runtime, store in
            var running = runtime
            running.port = 22093
            return try store.refresh(running)
        }
        let result = await runEnvUp(
            EnvUpOptions(platform: .android, deviceID: "emulator-5556", json: true), store: store,
            dependencies: dependencies
        )
        let report = try JSONDecoder().decode(EnvUpReport.self, from: Data(result.output.utf8))
        XCTAssertNil(report.timings?.app)
        XCTAssertNil(report.companion, "a child that recorded nothing leaves no companion report")
    }

    func testFailedStartStillReportsWhatTheChildGotThrough() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var dependencies = EnvUpDependencies()
        dependencies.resolve = { _, _ in
            EnvDeviceReport(id: "SIM", name: nil, os: nil, avd: nil, bootedByEnv: false)
        }
        dependencies.start = { _, runtime, store in
            CompanionStartPhases(path: store.companionPhasesURL(runtimeID: runtime.id).path)
                .record("build", outcome: "built", since: .now)
            throw EnvError.companionFailed("runner exited")
        }
        let result = await runEnvUp(
            EnvUpOptions(platform: .ios, deviceID: "SIM", json: true), store: store, dependencies: dependencies
        )
        XCTAssertNotEqual(result.exitCode, 0)
        let report = try JSONDecoder().decode(EnvUpReport.self, from: Data(result.output.utf8))
        XCTAssertEqual(report.companion?.build, "built")
        XCTAssertNil(report.timings?.companion)
    }

    func testAndroidSummaryNamesAnyReinstall() {
        let reused = EnvCompanionReport(phases: [
            .init(name: "build", outcome: "cached", milliseconds: 1),
            .init(name: "install.app", outcome: "reused", milliseconds: 300),
            .init(name: "install.test", outcome: "reused", milliseconds: 1),
            .init(name: "launch", outcome: "launched", milliseconds: 5000)
        ])
        XCTAssertEqual(reused.install, "reused")
        let reinstalled = EnvCompanionReport(phases: [
            .init(name: "install.app", outcome: "reused", milliseconds: 300),
            .init(name: "install.test", outcome: "installed", milliseconds: 9000)
        ])
        XCTAssertEqual(reinstalled.install, "installed")
    }

    func testAdoptedCompanionIsReusedWithNoBuild() {
        let adopted = EnvCompanionReport(phases: [
            .init(name: "check", outcome: "unchanged", milliseconds: 20),
            .init(name: "runner", outcome: "reused", milliseconds: 40)
        ])
        XCTAssertEqual(adopted.runner, "reused")
        XCTAssertNil(adopted.build)
    }

    func testRecorderWithoutAPathWritesNothing() throws {
        let scratch = try makeScratchDirectory()
        CompanionStartPhases(path: nil).record("check", outcome: "unchanged", since: .now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path), [])
        XCTAssertNil(CompanionStartPhases.read(path: scratch.url.appending(path: "missing.json").path))
    }
}

// swiftlint:enable multiline_arguments
