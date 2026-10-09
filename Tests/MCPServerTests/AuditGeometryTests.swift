import AmooCore
import MCP
@testable import MCPServer
import XCTest

final class AuditGeometryTests: XCTestCase {
    /// 126x126 px at 420 dpi is 48x48 dp; 105x105 px is 40x40 dp.
    private let androidScreen = ViewNode(id: "root", children: [
        ViewNode(id: "ok", label: "OK", type: .button, frame: Rect(x: 0, y: 0, width: 126, height: 126)),
        ViewNode(id: "close", label: "Close", type: .button, frame: Rect(x: 0, y: 200, width: 105, height: 105))
    ])

    private func tapTargetCoverage(_ driver: AuditMockDriver) async throws -> (Value?, String) {
        let server = MCPServer(executor: DriverToolExecutor(driver: driver))
        let result = await server.execute(toolName: "audit_accessibility", arguments: ["app_id": "com.test"])
        let coverage = result.structuredContent?.objectValue?["coverage"]?.objectValue
        return (coverage?["notEvaluated"]?.objectValue?["UX-002"], result.content)
    }

    func testAndroidPixelsAreNormalizedToDpWhenDensityIsKnown() async throws {
        let driver = AuditMockDriver(
            platform: .android,
            geometry: ElementGeometry(unit: "dp", framesPerUnit: 420.0 / 160),
            hierarchy: androidScreen
        )
        let (notEvaluated, content) = try await tapTargetCoverage(driver)
        XCTAssertNil(notEvaluated, "Tap-target rule must evaluate dp geometry")
        XCTAssertTrue(content.contains("1 element(s) have bounds below the 48-dp heuristic"), content)
    }

    func testAndroidWithoutDensityDeclinesTapTargetEvaluation() async throws {
        let driver = AuditMockDriver(platform: .android, hierarchy: androidScreen)
        let (notEvaluated, content) = try await tapTargetCoverage(driver)
        XCTAssertNotNil(notEvaluated)
        XCTAssertFalse(content.contains("heuristic"), content)
    }

    func testNativeAuditCategoriesTolerateSpacesAfterCommas() async {
        let result = await DriverToolExecutor(driver: MockDriver()).execute(
            toolName: "audit_accessibility_native",
            arguments: ["app_id": "com.example.frontmost", "categories": "contrast, hitRegion"]
        )
        XCTAssertFalse(result.content.contains("Requires supported"), result.content)
        XCTAssertEqual(
            result.structuredContent?.objectValue?["requestedChecks"],
            .array([.string("contrast"), .string("hitRegion")])
        )
    }

    func testAccessibilityAndSecurityAuditsAdvertiseFailOn() {
        for name in ["audit_accessibility", "audit_security", "audit_app"] {
            let definition = AuditTools.definitions.first { $0.name == name }
            XCTAssertNotNil(definition?.properties["fail_on"], name)
        }
    }
}
