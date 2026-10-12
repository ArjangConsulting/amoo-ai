@testable import CLI
import XCTest

// Compact inline fixtures keep each scenario's input beside its expectation.
// swiftlint:disable multiline_arguments

final class IOSCompanionPortTests: XCTestCase {
    private let iPhone = "6A1B2C3D-0000-4000-8000-000000000001"
    private let iPad = "6A1B2C3D-0000-4000-8000-000000000002"

    func testDerivedPortIsStableAndInsideTheDerivedRange() {
        let first = IOSCompanionPort.derived(forUDID: iPhone)
        XCTAssertEqual(first, IOSCompanionPort.derived(forUDID: iPhone))
        XCTAssertEqual(first, IOSCompanionPort.derived(forUDID: iPhone.lowercased()), "UDID case must not matter")
        let range = IOSCompanionPort.derivedBase ..< IOSCompanionPort.derivedBase + IOSCompanionPort.derivedSpan
        XCTAssertTrue(range.contains(first))
    }

    /// Regression for the single shared port: two simulators must not default to the same one.
    func testDistinctSimulatorsGetDistinctPortsAndNeverTheLegacyOrAndroidPorts() {
        XCTAssertNotEqual(IOSCompanionPort.derived(forUDID: iPhone), IOSCompanionPort.derived(forUDID: iPad))
        for index in 0 ..< 200 {
            let udid = "00000000-0000-4000-8000-\(String(format: "%012d", index))"
            let port = IOSCompanionPort.derived(forUDID: udid)
            XCTAssertNotEqual(port, CompanionConfig.defaultPort)
            XCTAssertGreaterThan(port, AndroidCompanionConfig.fallbackPortBase)
        }
    }

    func testRequestedPortWinsOverTheServerPortAndTheDerivedPort() async {
        let port = await IOSCompanionPort.resolve(
            requested: 24001, serverDefault: 24002, udid: iPhone, isPhysicalDevice: false,
            legacyPortOwner: { self.iPhone }
        )
        XCTAssertEqual(port, 24001)
    }

    func testServerPortIsUsedWhenTheSessionNamesNone() async {
        let port = await IOSCompanionPort.resolve(
            requested: nil, serverDefault: 24002, udid: iPhone, isPhysicalDevice: false,
            legacyPortOwner: { nil }
        )
        XCTAssertEqual(port, 24002)
    }

    func testNeitherGivenDerivesAPortFromTheUDID() async {
        let port = await IOSCompanionPort.resolve(
            requested: nil, serverDefault: nil, udid: iPad, isPhysicalDevice: false,
            legacyPortOwner: { self.iPhone }
        )
        XCTAssertEqual(port, IOSCompanionPort.derived(forUDID: iPad))
    }

    /// A companion left on 22087 by `amoo companion start` for the very same simulator is adopted,
    /// but one serving a different simulator is not.
    func testCompanionAlreadyOnTheLegacyPortForThisSimulatorIsAdopted() async {
        let adopted = await IOSCompanionPort.resolve(
            requested: nil, serverDefault: nil, udid: iPhone.lowercased(), isPhysicalDevice: false,
            legacyPortOwner: { self.iPhone }
        )
        XCTAssertEqual(adopted, CompanionConfig.defaultPort)
        let other = await IOSCompanionPort.resolve(
            requested: nil, serverDefault: nil, udid: iPad, isPhysicalDevice: false,
            legacyPortOwner: { self.iPhone }
        )
        XCTAssertNotEqual(other, CompanionConfig.defaultPort)
    }

    func testPhysicalDevicesNeverProbeTheLegacyPort() async {
        let port = await IOSCompanionPort.resolve(
            requested: nil, serverDefault: nil, udid: iPhone, isPhysicalDevice: true,
            legacyPortOwner: {
                XCTFail("a physical device is not behind a simulator companion")
                return self.iPhone
            }
        )
        XCTAssertEqual(port, IOSCompanionPort.derived(forUDID: iPhone))
    }

    func testMCPServeRemembersWhetherThePortWasExplicit() {
        guard case let .success(implicit) = parseMCPServeOptions(args: []),
              case let .success(explicit) = parseMCPServeOptions(args: ["--port", "24100"])
        else { return XCTFail("Expected parser success") }
        XCTAssertNil(implicit.explicitPort)
        XCTAssertEqual(implicit.port, 22087)
        XCTAssertEqual(explicit.explicitPort, 24100)
        XCTAssertEqual(explicit.port, 24100)
    }

    func testMismatchMessageTellsMCPClientsHowToPickAFreePort() {
        let message = companionMismatchMessage(port: 22087, requested: iPhone, owner: iPad)
        XCTAssertTrue(message.contains("attached to simulator \(iPad), not \(iPhone)"), message)
        XCTAssertTrue(message.contains("pass `port` to start_session"), message)
        XCTAssertTrue(message.contains("amoo mcp serve --port <free-port>"), message)
    }
}

// swiftlint:enable multiline_arguments
