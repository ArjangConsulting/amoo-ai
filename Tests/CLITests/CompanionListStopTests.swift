import AmooCore
@testable import CLI
import Foundation
import TestCommons
import XCTest

/// `companion list` / `companion stop` act on exactly the holders they are asked about.
final class CompanionListStopTests: XCTestCase {
    private final class FakeProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var alive: Set<Int32>
        private(set) var terminated: [Int32] = []
        private(set) var killed: [Int32] = []
        /// Pids that ignore SIGTERM and only die to SIGKILL.
        var stubborn: Set<Int32> = []

        init(alive: Set<Int32>) {
            self.alive = alive
        }

        func isAlive(_ pid: Int32) -> Bool {
            lock.withLock { alive.contains(pid) }
        }

        func terminate(_ pid: Int32) {
            lock.withLock {
                terminated.append(pid)
                if !stubborn.contains(pid) {
                    alive.remove(pid)
                }
            }
        }

        func forceKill(_ pid: Int32) {
            lock.withLock { killed.append(pid); alive.remove(pid) }
        }
    }

    private func makeHooks(
        registry: CompanionRegistry, processes: FakeProcesses, ready: Set<Int> = []
    ) -> CompanionListStopHooks {
        CompanionListStopHooks(
            registry: registry,
            isReady: { ready.contains($0) },
            isAlive: { processes.isAlive($0) },
            terminate: { processes.terminate($0) },
            forceKill: { processes.forceKill($0) },
            graceSeconds: 0.3
        )
    }

    private func register(
        _ registry: CompanionRegistry, pid: Int32, port: Int, device: String, app: String? = nil
    ) {
        registry.register(CompanionRegistration(
            pid: pid, platform: "ios", deviceID: device, port: port, appID: app, startedAt: Date()
        ))
    }

    func testListShowsPidPortDeviceAndState() async throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        register(registry, pid: 101, port: 22111, device: "AAA", app: "com.example")
        register(registry, pid: 102, port: 22112, device: "BBB")
        let hooks = makeHooks(registry: registry, processes: FakeProcesses(alive: [101, 102]), ready: [22111])

        let result = await runCompanionList(hooks: hooks)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("101\tios\t22111\tready\tAAA\tcom.example"), result.output)
        XCTAssertTrue(result.output.contains("102\tios\t22112\tstarting\tBBB\t-"), result.output)
    }

    func testListPrunesRecordsOfDeadHolders() async throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        register(registry, pid: 101, port: 22111, device: "AAA")
        let hooks = makeHooks(registry: registry, processes: FakeProcesses(alive: []))

        let result = await runCompanionList(hooks: hooks)

        XCTAssertTrue(result.output.contains("No companions running"), result.output)
        XCTAssertTrue(registry.entries(isAlive: { _ in true }).isEmpty, "the stale record is deleted")
    }

    func testStopByPortLeavesOtherCompanionsRunning() async throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        register(registry, pid: 101, port: 22111, device: "AAA")
        register(registry, pid: 102, port: 22112, device: "BBB")
        let processes = FakeProcesses(alive: [101, 102])
        var options = try XCTUnwrap(parsedOptions(["stop", "--port", "22111"]))
        options.all = false

        let result = await runCompanionStop(
            options: options,
            hooks: makeHooks(registry: registry, processes: processes)
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(processes.terminated, [101])
        XCTAssertTrue(processes.isAlive(102))
    }

    func testStopByDeviceMatchesCaseInsensitively() async throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        register(registry, pid: 101, port: 22111, device: "AAA-1")
        register(registry, pid: 102, port: 22112, device: "BBB-2")
        let processes = FakeProcesses(alive: [101, 102])
        let options = try XCTUnwrap(parsedOptions(["stop", "--device", "bbb-2"]))

        _ = await runCompanionStop(options: options, hooks: makeHooks(registry: registry, processes: processes))

        XCTAssertEqual(processes.terminated, [102])
    }

    func testBareStopRefusesToStopAnything() async throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        register(registry, pid: 101, port: 22111, device: "AAA")
        let processes = FakeProcesses(alive: [101])
        let options = try XCTUnwrap(parsedOptions(["stop"]))

        let result = await runCompanionStop(
            options: options,
            hooks: makeHooks(registry: registry, processes: processes)
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(processes.terminated.isEmpty)
    }

    func testStopAllStopsEveryHolder() async throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        register(registry, pid: 101, port: 22111, device: "AAA")
        register(registry, pid: 102, port: 22112, device: "BBB")
        let processes = FakeProcesses(alive: [101, 102])
        let options = try XCTUnwrap(parsedOptions(["stop", "--all"]))

        _ = await runCompanionStop(options: options, hooks: makeHooks(registry: registry, processes: processes))

        XCTAssertEqual(Set(processes.terminated), [101, 102])
    }

    func testStopEscalatesToKillWhenTermIsIgnored() async throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        register(registry, pid: 101, port: 22111, device: "AAA")
        let processes = FakeProcesses(alive: [101])
        processes.stubborn = [101]
        let options = try XCTUnwrap(parsedOptions(["stop", "--port", "22111"]))

        let result = await runCompanionStop(
            options: options,
            hooks: makeHooks(registry: registry, processes: processes)
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(processes.killed, [101])
    }

    func testStopWithNoMatchReportsIt() async throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        let options = try XCTUnwrap(parsedOptions(["stop", "--port", "22111"]))

        let result = await runCompanionStop(
            options: options, hooks: makeHooks(registry: registry, processes: FakeProcesses(alive: []))
        )

        XCTAssertEqual(result.exitCode, 1)
    }

    func testUnregisterIgnoresARecordOwnedByANewerHolder() throws {
        let registry = try CompanionRegistry(directory: makeScratchDirectory().url)
        register(registry, pid: 202, port: 22111, device: "AAA")

        registry.unregister(platform: "ios", port: 22111, pid: 101)

        XCTAssertEqual(registry.entries(isAlive: { _ in true }).map(\.pid), [202])
    }

    private func parsedOptions(_ args: [String]) -> CompanionCommandOptions? {
        if case let .success(options) = parseCompanionCommandOptions(args: args) {
            return options
        }
        return nil
    }
}
