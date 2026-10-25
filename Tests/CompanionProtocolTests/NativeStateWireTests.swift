import AmooCore
@testable import CompanionProtocol
import Protos
import XCTest

final class NativeStateWireTests: XCTestCase {
    func testFalseAndEmptyRemainPresentWhileUnavailablePropertiesStayAbsent() throws {
        var native = Amoo_ElementSemantics()
        native.isCheckable = true
        native.isChecked = false
        native.stateDescription = ""
        native.reference = "capture:node"
        let decoded = try Amoo_ElementSemantics(serializedBytes: native.serializedData()).coreSemantics
        XCTAssertEqual(decoded.isCheckable, true)
        XCTAssertEqual(decoded.isChecked, false)
        XCTAssertEqual(decoded.stateDescription, "")
        XCTAssertEqual(decoded.reference, "capture:node")
        let unavailable = Amoo_ElementSemantics().coreSemantics
        XCTAssertNil(unavailable.isChecked)
        XCTAssertNil(unavailable.stateDescription)
    }
}
