import AmooCore
import Foundation
@testable import ProcessRunner
import SwiftyShell
import TestCommons
import XCTest

final class AndroidEmulatorLifecycleTests: XCTestCase {
    func testDiscoveryIgnoresAuthenticationAndValidatesRegistrationFields() throws {
        let registration = try XCTUnwrap(AndroidEmulatorDiscovery.parse(
            "port.serial=5556\navd.id=Resizable\navd.dir=/tmp/Resizable.avd\ngrpc.token=secret-that-must-not-escape\n",
            filename: "pid_42.ini"
        ))
        XCTAssertEqual(registration.serial, "emulator-5556")
        XCTAssertEqual(registration.pid, 42)
        XCTAssertFalse(String(reflecting: registration).contains("secret-that-must-not-escape"))
        XCTAssertNil(AndroidEmulatorDiscovery.parse(
            "port.serial=5555\navd.id=Test\navd.dir=/tmp/avd",
            filename: "pid_42.ini"
        ))
        XCTAssertNil(AndroidEmulatorDiscovery.parse(
            "port.serial=5556\navd.id=Test\navd.dir=relative",
            filename: "pid_42.ini"
        ))
        XCTAssertNil(AndroidEmulatorDiscovery.parse(
            "port.serial=5556\navd.id=Test\navd.dir=/tmp/avd",
            filename: "pid_bad.ini"
        ))
    }

    func testProcessTableIdentifiesAnEmulatorThatWroteNoDiscoveryFile() async throws {
        let line = "13703 /sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64"
            + " -avd Pixel_Fold -no-snapshot-save -port 5554"
        let unrelated = [
            "100 /usr/bin/netsimd",
            "200 /sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Studio_Launched",
            "300 /sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Odd -port 5555"
        ]
        let context = ShellContext(executor: MockExecutor { _, _ in
            ShellOutput(stdout: ([line] + unrelated).joined(separator: "\n"), stderr: "", exitCode: 0)
        })
        let registrations = try await AndroidEmulatorDiscovery(context: context, directories: [], scansProcesses: true)
            .runningEmulators()
        XCTAssertEqual(registrations.map(\.pid), [13703])
        XCTAssertEqual(registrations.first?.serial, "emulator-5554")
        XCTAssertEqual(registrations.first?.avdID, "Pixel_Fold")
        XCTAssertEqual(registrations.first?.directory.lastPathComponent, "Pixel_Fold.avd")
    }

    func testInjectedDirectoriesDoNotScanTheProcessTable() async throws {
        let context = ShellContext(executor: MockExecutor { _, _ in
            ShellOutput(stdout: "1 /sdk/qemu-system-aarch64 -avd Any -port 5554", stderr: "", exitCode: 0)
        })
        let registrations = try await AndroidEmulatorDiscovery(context: context, directories: []).runningEmulators()
        XCTAssertTrue(registrations.isEmpty)
    }

    func testDiscoveryExcludesAReusedPIDBelongingToAnotherAVD() async throws {
        let scratch = try makeRegistry()
        defer { try? scratch.remove() }
        let context = ShellContext(executor: MockExecutor { _, _ in
            ShellOutput(stdout: "/sdk/qemu-system-aarch64 -avd Different_AVD", stderr: "", exitCode: 0)
        })
        let registrations = try await AndroidEmulatorDiscovery(context: context, directories: [scratch.url])
            .runningEmulators()
        XCTAssertTrue(registrations.isEmpty)
    }

    func testShutdownWaitsForProcessExitAfterADBDisappears() async throws {
        let scratch = try makeRegistry()
        defer { try? scratch.remove() }
        let script = ShutdownScript(processResponses: [true, true, false], deviceResponses: [false])
        let runner = ADBRunner(context: script.context, emulatorDiscoveryDirectories: [scratch.url], shutdownTimeout: 2)
        try await runner.killEmulator(serial: "emulator-5556")
        let counts = await script.counts()
        XCTAssertEqual(counts.kills, 1)
        XCTAssertEqual(counts.processReads, 3)
        XCTAssertEqual(counts.deviceReads, 2)
    }

    func testShutdownWaitsForADBDisconnectAfterProcessExit() async throws {
        let scratch = try makeRegistry()
        defer { try? scratch.remove() }
        let script = ShutdownScript(processResponses: [true, false], deviceResponses: [true, false])
        let runner = ADBRunner(context: script.context, emulatorDiscoveryDirectories: [scratch.url], shutdownTimeout: 2)
        try await runner.killEmulator(serial: "emulator-5556")
        let counts = await script.counts()
        XCTAssertEqual(counts.deviceReads, 2)
    }

    func testShutdownDoesNotReportSuccessWhileProcessKeepsTheAVDLocked() async throws {
        let scratch = try makeRegistry()
        defer { try? scratch.remove() }
        let script = ShutdownScript(processResponses: [true], deviceResponses: [false])
        let runner = ADBRunner(
            context: script.context,
            emulatorDiscoveryDirectories: [scratch.url],
            shutdownTimeout: 0.03
        )
        do {
            try await runner.killEmulator(serial: "emulator-5556")
            XCTFail("An acknowledgement must not count as completed shutdown")
        } catch let AmooError.commandFailed(command, output) {
            XCTAssertEqual(command, "device_shutdown")
            XCTAssertTrue(output.contains("has not exited"))
            XCTAssertTrue(output.contains("unverified"))
        }
    }

    func testUnresponsiveConsoleUsesOnlyTheVerifiedEmulatorPID() async throws {
        let scratch = try makeRegistry()
        defer { try? scratch.remove() }
        let script = ShutdownScript(processResponses: [true], deviceResponses: [false], consoleFails: true)
        let runner = ADBRunner(context: script.context, emulatorDiscoveryDirectories: [scratch.url], shutdownTimeout: 2)
        try await runner.killEmulator(serial: "emulator-5556")
        let counts = await script.counts()
        XCTAssertEqual(counts.terminationArguments, [["-TERM", "42"]])
    }

    func testConsoleTimeoutDoesNotSignalAPIDThatNoLongerIdentifiesTheEmulator() async throws {
        let scratch = try makeRegistry()
        defer { try? scratch.remove() }
        let script = ShutdownScript(processResponses: [true, false], deviceResponses: [false], consoleFails: true)
        let runner = ADBRunner(context: script.context, emulatorDiscoveryDirectories: [scratch.url], shutdownTimeout: 2)
        try await runner.killEmulator(serial: "emulator-5556")
        let counts = await script.counts()
        XCTAssertTrue(counts.terminationArguments.isEmpty)
    }

    private func makeRegistry() throws -> TemporaryDirectory {
        let scratch = try TemporaryDirectory()
        try "port.serial=5556\navd.id=Test_AVD\navd.dir=/tmp/Test_AVD.avd\n".write(
            to: scratch.url.appendingPathComponent("pid_42.ini"), atomically: true, encoding: .utf8
        )
        return scratch
    }
}

private actor ShutdownScript {
    struct Counts {
        let kills: Int
        let processReads: Int
        let deviceReads: Int
        let terminationArguments: [[String]]
    }

    private var processResponses: [Bool]
    private var deviceResponses: [Bool]
    private var kills = 0
    private var processReads = 0
    private var deviceReads = 0
    private var terminationArguments: [[String]] = []
    private let consoleFails: Bool

    init(processResponses: [Bool], deviceResponses: [Bool], consoleFails: Bool = false) {
        self.processResponses = processResponses
        self.deviceResponses = deviceResponses
        self.consoleFails = consoleFails
    }

    nonisolated var context: ShellContext {
        ShellContext(executor: MockExecutor { command, _ in try await self.execute(command) })
    }

    func counts() -> Counts {
        Counts(
            kills: kills,
            processReads: processReads,
            deviceReads: deviceReads,
            terminationArguments: terminationArguments
        )
    }

    private func execute(_ command: Command) throws -> ShellOutput {
        let stdout: String
        if command.executableName == "ps" {
            processReads += 1
            let running = processResponses.count > 1 ? processResponses.removeFirst() : processResponses[0]
            stdout = running ? "/sdk/qemu-system-aarch64 -avd Test_AVD -port 5556" : ""
        } else if command.executableName == "kill" {
            terminationArguments.append(command.arguments)
            processResponses = [false]
            stdout = ""
        } else if command.arguments.contains("kill") {
            kills += 1
            if consoleFails {
                throw AmooError.timeout(operation: "emu kill", duration: Duration(milliseconds: 3000))
            }
            stdout = "OK"
        } else {
            deviceReads += 1
            let online = deviceResponses.count > 1 ? deviceResponses.removeFirst() : deviceResponses[0]
            stdout = "List of devices attached\n" + (online ? "emulator-5556 device\n" : "")
        }
        return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
    }
}
