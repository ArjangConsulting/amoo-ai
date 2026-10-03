@testable import CLI
import XCTest

final class SimulatorRuntimeTests: XCTestCase {
    /// Regression: `simctl boot` failing on a missing runtime image was swallowed, and the later
    /// `bootstatus` failure was reported as "timed out" in under a second.
    func testMissingRuntimeBootErrorIsSurfaced() {
        let stderr = "An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):\n"
            + "The iOS 27.0 simulator runtime is not available.\nruntime path not found"
        let failure = simulatorBootFailure(exitCode: 2, stderr: stderr)
        XCTAssertTrue(failure?.contains("runtime is not available") == true, "\(failure ?? "nil")")
    }

    func testRacingBooterIsNotAFailure() {
        XCTAssertNil(simulatorBootFailure(
            exitCode: 163,
            stderr: "Unable to boot device in current state: Booted"
        ))
        XCTAssertNil(simulatorBootFailure(exitCode: 0, stderr: nil))
        XCTAssertNil(simulatorBootFailure(exitCode: nil, stderr: nil))
    }

    func testDoctorFlagsUnavailableRuntimesAndTheirSimulators() {
        let runtimes = """
        {"runtimes":[
          {"name":"iOS 27.0","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","isAvailable":false,
           "availabilityError":"runtime path not found"},
          {"name":"iOS 27.2","identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2","isAvailable":true}
        ]}
        """
        let devices = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
            {"name":"iPhone 17","udid":"AAAA","isAvailable":false,"availabilityError":"runtime path not found"}],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2":[
            {"name":"iPhone 17","udid":"BBBB","isAvailable":true}]
        }}
        """
        let problems = parseUnavailableSimulatorProblems(runtimesJSON: runtimes, devicesJSON: devices)
        XCTAssertEqual(problems.count, 2)
        XCTAssertTrue(problems[0].contains("iOS 27.0") && problems[0].contains("runtime path not found"))
        XCTAssertTrue(problems[1].contains("AAAA"))
        XCTAssertTrue(parseUnavailableSimulatorProblems(runtimesJSON: "", devicesJSON: "garbage").isEmpty)
    }
}
