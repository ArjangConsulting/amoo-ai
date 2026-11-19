import AmooCore
@testable import MCPServer
import XCTest

/// A mismatch said "see last observed state" and left the state to the structured result, which a
/// flow run did not print. The message now names what the last read saw.
final class AssertionMessageTests: XCTestCase {
    func testMismatchMessageCarriesTheLastObservedElement() {
        let summary = DriverToolExecutor.observedSummary(
            ElementInfo(id: "play", label: "Play", value: "0", isSelected: false), reads: 3
        )
        XCTAssertEqual(summary, "[play] Play visible=true enabled=true value=\"0\" selected=false")
        XCTAssertEqual(DriverToolExecutor.observedSummary(nil, reads: 2), "no element matching the selector")
        let secure = DriverToolExecutor.observedSummary(
            ElementInfo(id: "pw", label: "Password", value: "hunter2", isSecureTextEntry: true), reads: 1
        )
        XCTAssertFalse(secure.contains("hunter2"), secure)
    }
}
