import AmooCore
@testable import CLI
import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DeviceAccessHolderTests: XCTestCase {
    func testRefusalNamesTheHoldingProcess() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let access = try DeviceAccessLock(deviceID: "emulator-5554", store: store)
        defer { access.release() }

        XCTAssertThrowsError(try DeviceAccessLock(deviceID: "emulator-5554", store: store)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("pid \(getpid())"), message)
            XCTAssertTrue(message.contains("--kill-stale"), message)
        }
    }

    func testReleaseClearsTheHolderRecord() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let path = lockPath(store, "SIM")
        let access = try DeviceAccessLock(deviceID: "SIM", store: store)
        XCTAssertEqual(DeviceAccessHolder.read(path: path)?.pid, getpid())
        access.release()
        XCTAssertNil(DeviceAccessHolder.read(path: path))
    }

    func testUnrecordedHolderIsStillRefusedAndSaysSo() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let path = lockPath(store, "SIM")
        try FileManager.default.createDirectory(at: store.accessDirectory, withIntermediateDirectories: true)
        let foreign = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { close(foreign) }
        XCTAssertEqual(flock(foreign, LOCK_EX | LOCK_NB), 0)

        XCTAssertThrowsError(try DeviceAccessLock(deviceID: "SIM", store: store)) { error in
            XCTAssertTrue("\(error)".contains("holder not recorded"), "\(error)")
        }
    }

    func testLockHeldPastItsDeadRecordedOwnerIsRecovered() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let path = lockPath(store, "SIM")
        try FileManager.default.createDirectory(at: store.accessDirectory, withIntermediateDirectories: true)
        let leaked = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { close(leaked) }
        XCTAssertEqual(flock(leaked, LOCK_EX | LOCK_NB), 0)
        try DeviceAccessHolder(pid: exitedPID(), command: "amoo mcp serve", acquiredAt: Date()).write(to: leaked)

        let access = try DeviceAccessLock(deviceID: "SIM", store: store)
        defer { access.release() }
        XCTAssertEqual(DeviceAccessHolder.read(path: path)?.pid, getpid())
    }

    func testDoctorReportsHeldLocksOnly() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let access = try DeviceAccessLock(deviceID: "emulator-5554", store: store)
        let held = doctorDeviceLocks(store: store)
        XCTAssertEqual(held.map(\.device), ["emulator-5554"])
        XCTAssertEqual(held.first?.pid, getpid())
        XCTAssertEqual(held.first?.holderRunning, true)

        access.release()
        XCTAssertTrue(doctorDeviceLocks(store: store).isEmpty)
    }

    func testDoctorIgnoresARecordLeftByACrashedHolder() throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let path = lockPath(store, "SIM")
        try FileManager.default.createDirectory(at: store.accessDirectory, withIntermediateDirectories: true)
        let file = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { close(file) }
        try DeviceAccessHolder(pid: exitedPID(), command: "amoo mcp serve", acquiredAt: Date()).write(to: file)

        XCTAssertTrue(doctorDeviceLocks(store: store).isEmpty)
    }

    func testDoctorTiesAStaleServerToTheDeviceItHolds() {
        let lock = DoctorDeviceLock(
            device: "emulator-5554",
            pid: 42,
            command: "amoo mcp serve",
            acquiredAt: Date(),
            holderRunning: true,
            lockPath: "/tmp/lock"
        )
        let stale = DoctorMCPServer(pid: 42, binary: "/test/amoo", arguments: "amoo mcp serve", stale: true)
        let report = DoctorReport(
            ok: true,
            cli: .init(version: "test"),
            mcpServers: [stale],
            adbServerRunning: false,
            devices: [],
            companions: [],
            runtimes: [],
            issues: [],
            notes: [],
            deviceLocks: [lock]
        )
        XCTAssertEqual(doctorDeviceLockIssues(report).count, 1)
        XCTAssertTrue(doctorDeviceLockIssues(report)[0].contains("--mcp-pid 42 --kill-stale"))
        XCTAssertTrue(doctorDeviceLockNotes(report).isEmpty)
    }

    func testDoctorNamesTheSafeRecoveryForAnUnresponsiveCompanion() {
        let report = DoctorReport(
            ok: true,
            cli: .init(version: "test"),
            mcpServers: [],
            adbServerRunning: false,
            devices: [],
            companions: [
                .init(port: 22088, pid: 29777, process: nil, device: "emulator-5554", state: .unresponsive),
                .init(port: 22089, pid: 1, process: nil, device: "emulator-5556", state: .running)
            ],
            runtimes: [],
            issues: [],
            notes: []
        )
        let notes = doctorUnresponsiveCompanionNotes(report)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("amoo env down --device emulator-5554"))
        XCTAssertTrue(notes[0].contains("pid 29777"))
        XCTAssertFalse(notes[0].contains("--kill-stale"))
    }

    private func lockPath(_ store: DeviceRuntimeStore, _ deviceID: String) -> String {
        store.accessFileURL(deviceID: deviceID).appendingPathExtension("session-lock").path
    }

    private func exitedPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
