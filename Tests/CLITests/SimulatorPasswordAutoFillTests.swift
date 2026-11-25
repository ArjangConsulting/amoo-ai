@testable import CLI
import Foundation
import TestCommons
import XCTest

/// `env up --disable-password-autofill` writes iOS's own restriction into the simulator's settings
/// before booting it, so a sign-in never brings up "Save Password?", which the accessibility tree
/// cannot show once it has settled.
final class SimulatorPasswordAutoFillTests: XCTestCase {
    private func settings(
        autoFill: Bool?,
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) throws -> URL {
        var restricted: [String: Any] = ["allowCamera": ["value": true]]
        if let autoFill {
            restricted["allowPasswordAutoFill"] = ["value": autoFill]
        }
        let plist: [String: Any] = ["restrictedBool": restricted, "union": ["allowedDomains": ["values": []]]]
        let url = try makeScratchDirectory().url.appending(path: "UserSettings.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0).write(to: url)
        return url
    }

    private func format(of url: URL) throws -> PropertyListSerialization.PropertyListFormat {
        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: &format)
        return format
    }

    func testTurningItOffChangesOnlyThatSettingAndKeepsTheFormat() throws {
        for original in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let url = try settings(autoFill: true, format: original)
            XCTAssertEqual(SimulatorPasswordAutoFill.isOff(at: url), false)

            XCTAssertTrue(try SimulatorPasswordAutoFill.turnOff(at: url))

            XCTAssertEqual(SimulatorPasswordAutoFill.isOff(at: url), true)
            XCTAssertEqual(try format(of: url), original)
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
            )
            let restricted = try XCTUnwrap(plist["restrictedBool"] as? [String: Any])
            XCTAssertEqual((restricted["allowCamera"] as? [String: Any])?["value"] as? Bool, true)
            XCTAssertNotNil(plist["union"], "the rest of the settings stay")
        }
    }

    func testSettingsWithoutTheRestrictionAreLeftUnchanged() throws {
        let url = try settings(autoFill: nil)
        let before = try Data(contentsOf: url)

        XCTAssertFalse(try SimulatorPasswordAutoFill.turnOff(at: url))

        XCTAssertNil(SimulatorPasswordAutoFill.isOff(at: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testASimulatorThatNeverBootedHasNoSettingsYet() throws {
        let home = try makeScratchDirectory().url
        let url = SimulatorPasswordAutoFill.settingsURL(udid: "0000-SIM", home: home)
        XCTAssertTrue(url.path.hasPrefix(home.path + "/Library/Developer/CoreSimulator/Devices/0000-SIM/data/"))
        XCTAssertEqual(url.lastPathComponent, "UserSettings.plist")
        XCTAssertNil(SimulatorPasswordAutoFill.isOff(at: url))
        XCTAssertThrowsError(try SimulatorPasswordAutoFill.turnOff(at: url))
    }

    func testARunningSimulatorIsNeverRestartedAndANeverBootedOneIsBootedOnceFirst() async throws {
        var boots = 0
        let on = try settings(autoFill: true)
        let running = try await SimulatorPasswordAutoFill.turnOffBeforeBoot(udid: "s", running: true, settings: on) {
            boots += 1
        }
        XCTAssertEqual(running, .leftOn)
        XCTAssertEqual(SimulatorPasswordAutoFill.isOff(at: on), false, "a running simulator's file is not touched")

        let stopped = try await SimulatorPasswordAutoFill.turnOffBeforeBoot(udid: "s", running: false, settings: on) {
            boots += 1
        }
        XCTAssertEqual(stopped, .disabled)
        let again = try await SimulatorPasswordAutoFill.turnOffBeforeBoot(udid: "s", running: true, settings: on) {
            boots += 1
        }
        XCTAssertEqual(again, .alreadyOff)
        XCTAssertEqual(boots, 0)

        let fresh = try makeScratchDirectory().url.appending(path: "UserSettings.plist")
        let written = try settings(autoFill: true)
        let outcome = try await SimulatorPasswordAutoFill
            .turnOffBeforeBoot(udid: "s", running: false, settings: fresh) {
                boots += 1
                try FileManager.default.copyItem(at: written, to: fresh)
            }
        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(boots, 1)
        XCTAssertEqual(SimulatorPasswordAutoFill.isOff(at: fresh), true)
    }

    func testTheFlagIsForAnIOSSimulatorEnvUpBoots() {
        let parsed = parseEnvCommand(args: ["up", "--platform", "ios", "--disable-password-autofill"])
        guard case let .success(.up(options)) = parsed else { return XCTFail("\(parsed)") }
        XCTAssertTrue(options.disablePasswordAutoFill)
        for arguments in [
            ["up", "--platform", "android", "--disable-password-autofill"],
            ["up", "--platform", "ios", "--runtime-id", "rt-1", "--disable-password-autofill"]
        ] {
            guard case .failure = parseEnvCommand(args: arguments) else { return XCTFail("accepted \(arguments)") }
        }
    }

    func testTheReportSaysWhatToDoWhenTheSimulatorWasAlreadyRunning() throws {
        var device = EnvDeviceReport(id: "0000-SIM", name: "iPhone", os: "iOS 27.0", avd: nil, bootedByEnv: false)
        device.passwordAutoFill = .leftOn
        let json = try XCTUnwrap(String(bytes: JSONEncoder().encode(device), encoding: .utf8))
        XCTAssertTrue(json.contains(#""password_autofill":"left_on""#), json)
        XCTAssertTrue(SimulatorPasswordAutoFill.Outcome.leftOn.summary(udid: "0000-SIM")
            .contains("xcrun simctl shutdown 0000-SIM"))
    }
}
