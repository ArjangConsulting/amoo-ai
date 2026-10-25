import AmooCore
@testable import CompanionProtocol
import Protos
import XCTest

final class NativeAuditTargetClientTests: XCTestCase {
    func testAnonymousNativeIssueRetainsGeometryAndCaptureReferenceOverTheWire() async throws {
        let rpc = MockRPCClient()
        try await rpc.stubAnonymousNativeIssue()
        let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
        let report = try await client.inspectAccessibility(
            appID: "com.test", operation: "nativeAudit", categories: ["hitRegion"], steps: 1, direction: "forward"
        )
        let issue = try XCTUnwrap(report.issues.first)
        XCTAssertEqual(issue.elementID, "")
        XCTAssertEqual(issue.label, "")
        XCTAssertEqual(issue.frame, Rect(x: 40, y: 80, width: 8, height: 8))
        XCTAssertEqual(issue.semantics?.reference, "capture:issue[0]")
        XCTAssertEqual(issue.semantics?.attributes["coordinateUnit"], "points")
        XCTAssertEqual(issue.value, "100%")
        XCTAssertEqual(issue.elementType, "image")
    }
}

extension MockRPCClient {
    func stubAnonymousNativeIssue() throws {
        inspection.capabilityKeys = ["accessibility.nativeAudit"]
        var issue = Amoo_AccessibilityInspectionIssue()
        issue.category = "hitRegion"
        issue.description_p = "Small target"
        issue.element.frame = Amoo_Rect.with {
            $0.x = 40
            $0.y = 80
            $0.width = 8
            $0.height = 8
        }
        issue.element.type = "image"
        issue.element.value = "100%"
        issue.element.semantics.reference = "capture:issue[0]"
        issue.element.semantics.attributes = ["coordinateUnit": "points"]
        var response = Amoo_AccessibilityInspectionResponse()
        response.provider = "appleNativeAudit"
        response.status = "fail"
        response.issues = [issue]
        response.requestedChecks = ["hitRegion"]
        response.evaluatedChecks = ["hitRegion"]
        inspection.response = try Amoo_AccessibilityInspectionResponse(serializedBytes: response.serializedData())
    }
}
