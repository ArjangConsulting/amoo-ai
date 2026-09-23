@testable import CLI
import ProcessRunner
import XCTest

final class CompanionOwnershipTests: XCTestCase {
    private let iPhone = "B3337CA4-4759-4309-A2A8-1674A1CB6370"
    private let iPad = "E5989F82-C2CF-407D-938D-06059724A1B6"

    // MARK: - Resolving the companion's simulator

    func testSimulatorUDIDIsReadFromTheRunnerExecutablePath() {
        let path = "/Users/me/Library/Developer/CoreSimulator/Devices/\(iPad)/data/Containers/Bundle/"
            + "Application/19D0BF3C-0D26-4A34-9EDD-5F94FBEF00CC/AmooCompanionUITests-Runner.app/"
            + "AmooCompanionUITests-Runner\n"
        XCTAssertEqual(simulatorUDID(inExecutablePath: path), iPad)
    }

    func testSimulatorUDIDIsNormalizedToUppercase() {
        let path = "/x/CoreSimulator/Devices/\(iPad.lowercased())/data/Runner"
        XCTAssertEqual(simulatorUDID(inExecutablePath: path), iPad)
    }

    func testPathsOutsideASimulatorContainerHaveNoUDID() {
        XCTAssertNil(simulatorUDID(inExecutablePath: "/opt/homebrew/bin/iproxy"))
        XCTAssertNil(simulatorUDID(inExecutablePath: "/x/CoreSimulator/Devices/not-a-udid/data/Runner"))
        XCTAssertNil(simulatorUDID(inExecutablePath: "/x/Devices/\(iPad)/data/Runner"))
        XCTAssertNil(simulatorUDID(inExecutablePath: ""))
    }

    func testListenerPIDIsTheFirstProcessRecord() {
        XCTAssertEqual(listenerPID(fromLsofOutput: "p87762\nf27\np90000\nf12\n"), 87762)
        XCTAssertNil(listenerPID(fromLsofOutput: ""))
        XCTAssertNil(listenerPID(fromLsofOutput: "f27\n"))
    }

    func testCompanionSimulatorUDIDFollowsTheListenerToItsDevice() async {
        let runner = MockCLIProcessRunner(results: [
            .success(ProcessResult(exitCode: 0, stdout: "p87762\nf27\n", stderr: "")),
            .success(ProcessResult(
                exitCode: 0,
                stdout: "/Users/me/Library/Developer/CoreSimulator/Devices/\(iPad)/data/Runner\n",
                stderr: ""
            ))
        ])

        let udid = await companionSimulatorUDID(port: 22087, processRunner: runner)

        XCTAssertEqual(udid, iPad)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.first, ["/usr/sbin/lsof", "-nP", "-iTCP:22087", "-sTCP:LISTEN", "-Fp"])
        XCTAssertEqual(commands.last, ["/bin/ps", "-p", "87762", "-o", "comm="])
    }

    func testCompanionSimulatorUDIDIsNilWhenNothingListens() async {
        // lsof exits 1 when no process matches.
        let runner = MockCLIProcessRunner(results: [
            .success(ProcessResult(exitCode: 1, stdout: "", stderr: ""))
        ])
        let udid = await companionSimulatorUDID(port: 22087, processRunner: runner)
        XCTAssertNil(udid)
    }

    // MARK: - Ownership decision

    func testOwnershipMatchesTheRequestedSimulator() {
        XCTAssertEqual(CompanionOwnership(requested: iPhone, owner: iPhone), .matches)
        XCTAssertEqual(CompanionOwnership(requested: iPhone.lowercased(), owner: iPhone), .matches)
    }

    func testOwnershipFlagsADifferentSimulator() {
        XCTAssertEqual(CompanionOwnership(requested: iPhone, owner: iPad), .otherDevice(iPad))
    }

    func testOwnershipIsUnknownWhenTheCompanionCannotBeResolved() {
        XCTAssertEqual(CompanionOwnership(requested: iPhone, owner: nil), .unknown)
    }

    func testNonSpecificRequestsAlwaysMatch() {
        XCTAssertEqual(CompanionOwnership(requested: "booted", owner: iPad), .matches)
        XCTAssertEqual(CompanionOwnership(requested: "iPhone 17", owner: iPad), .matches)
        XCTAssertEqual(CompanionOwnership(requested: "00008110-001A2B3C4D5E801E", owner: iPad), .matches)
    }

    // MARK: - `amoo device`

    func testDeviceCommandRefusesAnotherSimulatorsCompanion() async {
        let iPad = iPad
        let result = await runDeviceCommand(
            options: DeviceCommandOptions(
                platform: .ios, port: 22087, deviceID: iPhone, tool: "current_app", arguments: [:]
            ),
            resolveCompanionDevice: { _ in iPad }
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("attached to simulator \(iPad), not \(iPhone)"), result.output)
        XCTAssertTrue(
            result.output.contains("amoo companion start --platform ios --device \(iPhone) --port"),
            result.output
        )
        XCTAssertTrue(result.output.contains("amoo device --device \(iPhone) --port"), result.output)
    }

    func testDeviceCommandDoesNotResolveOwnershipForAndroid() async {
        let result = await runDeviceCommand(
            options: DeviceCommandOptions(
                platform: .android, port: -1, deviceID: nil, tool: "current_app", arguments: [:]
            ),
            resolveCompanionDevice: { _ in
                XCTFail("Android serials are not simulator UDIDs; ownership must not be checked")
                return nil
            }
        )
        XCTAssertEqual(result.exitCode, 1)
    }

    // MARK: - `amoo companion --port`

    func testCompanionCommandAcceptsAPort() {
        let parsed = parseCompanionCommandOptions(args: ["start", "--device", iPhone, "--port", "22090"])
        guard case let .success(options) = parsed else {
            return XCTFail("Expected --port to parse")
        }
        XCTAssertEqual(options.port, 22090)
        XCTAssertEqual(options.deviceID, iPhone)
    }

    func testCompanionCommandDefaultsToNoPortOverride() {
        guard case let .success(options) = parseCompanionCommandOptions(args: ["status"]) else {
            return XCTFail("Expected status to parse")
        }
        XCTAssertNil(options.port)
    }

    func testCompanionCommandRejectsAnInvalidPort() {
        for value in ["abc", "0", "70000", "-5"] {
            guard case let .failure(error) = parseCompanionCommandOptions(args: ["start", "--port", value]) else {
                return XCTFail("Expected '\(value)' to be rejected")
            }
            XCTAssertEqual(error.description, "--port expects a port number between 1 and 65535, got '\(value)'.")
        }
    }
}
