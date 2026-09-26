import AmooCore
@testable import CLI
import Foundation
import MCP
import XCTest

final class EnvCommandParsingTests: XCTestCase {
    func testEnvUpParsesAndroidFlagsInAnyOrder() {
        let parsed = parseEnvCommand(args: [
            "up", "--json", "--avd", "Medium_Phone_API_35", "--platform", "android",
            "--app", "/tmp/a.apk", "--app-id", "com.app", "--launch", "--ttl", "30"
        ])
        guard case let .success(.up(options)) = parsed else { return XCTFail("\(parsed)") }
        XCTAssertEqual(options.platform, .android)
        XCTAssertEqual(options.avd, "Medium_Phone_API_35")
        XCTAssertEqual(options.appID, "com.app")
        XCTAssertTrue(options.launch)
        XCTAssertTrue(options.json)
        XCTAssertEqual(options.ttlMinutes, 30)
    }

    func testEnvRejectsTyposAndMissingValues() {
        for args in [
            ["up", "--platform", "android", "--avdd", "X"],
            ["up", "--platform", "android", "--avd"],
            ["up"],
            ["up", "--platform", "ios", "--avd", "X"],
            ["up", "--platform", "android", "--launch"],
            ["down"],
            ["sideways"]
        ] {
            guard case .failure = parseEnvCommand(args: args) else { return XCTFail("accepted \(args)") }
        }
    }

    func testIOSRuntimeNormalization() {
        XCTAssertEqual(normalizedIOSRuntime("iOS-27.0"), "27.0")
        XCTAssertEqual(normalizedIOSRuntime("iOS 27.1"), "27.1")
        XCTAssertEqual(normalizedIOSRuntime("27"), "27.0")
    }

    func testPickIOSSimulatorPrefersBootedAndSkipsLeased() {
        let sims = [
            IOSSimulatorDevice(udid: "A", name: "iPhone 17e", osVersion: "27.0"),
            IOSSimulatorDevice(udid: "B", name: "iPhone 17e", osVersion: "27.0"),
            IOSSimulatorDevice(udid: "C", name: "iPhone 17e", osVersion: "27.0"),
            IOSSimulatorDevice(udid: "D", name: "iPhone 17", osVersion: "27.0")
        ]
        let picked = pickIOSSimulator(
            runtime: "iOS-27.0",
            model: "iphone 17e",
            available: sims,
            bootedUDIDs: ["C", "B"],
            isLeased: { $0 == "B" }
        )
        XCTAssertEqual(picked?.udid, "C")
        XCTAssertNil(pickIOSSimulator(
            runtime: "26.0",
            model: nil,
            available: sims,
            bootedUDIDs: [],
            isLeased: { _ in false }
        ))
    }

    func testFreePortSkipsListeningAndLeasedPorts() async {
        let port = await pickFreeCompanionPort(candidates: 22093 ... 22099, leasedPorts: [22094]) { $0 == 22093 }
        XCTAssertEqual(port, 22095)
    }
}

final class ProbeCommandTests: XCTestCase {
    func testParsesFilesAndFlags() {
        let parsed = parseProbeRunOptions(args: [
            "--platform", "android", "a.js", "--device", "emulator-5554", "b.js", "--expect-pass", "--bail", "--json"
        ])
        guard case let .success(options) = parsed else { return XCTFail("\(parsed)") }
        XCTAssertEqual(options.files, ["a.js", "b.js"])
        XCTAssertEqual(options.deviceID, "emulator-5554")
        XCTAssertTrue(options.expectPass && options.bail && options.json)
    }

    func testRequiresDeviceAndFiles() {
        let missingDevice = parseProbeRunOptions(args: ["--platform", "android", "a.js"])
        guard case .failure = missingDevice else { return XCTFail("--device is required") }
        let missingFiles = parseProbeRunOptions(args: ["--platform", "android", "--device", "x"])
        guard case .failure = missingFiles else { return XCTFail("a probe file is required") }
    }

    /// Probes return a JSON *string* (`JSON.stringify(...)`), which CDP serializes again.
    func testInterpretsStringifiedAndPlainObjects() {
        let stringified = interpretProbeValue(
            #""{\"probe\":\"seek\",\"pass\":true,\"details\":{\"n\":2}}""#,
            fallbackName: "f"
        )
        XCTAssertEqual(stringified.name, "seek")
        XCTAssertEqual(stringified.pass, true)
        XCTAssertEqual(stringified.details, .object(["n": .int(2)]))

        let plain = interpretProbeValue(#"{"pass":false}"#, fallbackName: "f")
        XCTAssertEqual(plain.name, "f")
        XCTAssertEqual(plain.pass, false)

        XCTAssertNil(interpretProbeValue("42", fallbackName: "f").pass)
    }
}

final class DoctorParsingTests: XCTestCase {
    func testFindsOnlyAmooMCPServers() {
        let ps = """
          69683 Wed Sep 23 12:28:12 2026     /x/.build/release/amoo mcp serve --platform ios
          28531 Thu Sep 24 13:57:17 2026     amoo mcp serve
          73522 Thu Sep 24 02:01:54 2026     /x/amoo device --platform android describe_screen
          29817 Thu Sep 24 16:19:54 2026     /Apps/disclaimer --pgroup -- /opt/amoo mcp serve
        """
        let rows = parseMCPServerRows(ps)
        XCTAssertEqual(rows.map(\.pid), [69683, 28531])
        XCTAssertNotNil(rows.first?.startedAt)
    }

    func testLsofParsers() {
        XCTAssertEqual(
            parseLsofExecutables("p10\nn/bin/amoo\nn/usr/lib/dyld\np11\nn/opt/amoo\n"),
            [10: "/bin/amoo", 11: "/opt/amoo"]
        )
        let listeners = parseCompanionListeners(
            "p1\ncadb\nn127.0.0.1:22093\np2\ncAmooCompa\nn127.0.0.1:22090\np3\ncnode\nn*:3000\n",
            ports: 22080 ... 22199
        )
        XCTAssertEqual(listeners.map(\.port), [22090, 22093])
        XCTAssertEqual(listeners.first?.process, "AmooCompa")
    }
}
