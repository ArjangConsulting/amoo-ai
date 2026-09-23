import AmooCore
@testable import MCPServer
import XCTest

final class HierarchySummaryTests: XCTestCase {
    /// iOS names every node, containers included; only controls count as interactable.
    func testNamedContainersAreNotInteractable() {
        let frame = Rect(x: 0, y: 0, width: 44, height: 44)
        let root = ViewNode(id: "root", type: .other, frame: frame, children: [
            ViewNode(id: "root", type: .other, frame: frame, children: [
                ViewNode(id: "Today", label: "Today", type: .button, frame: frame),
                ViewNode(id: "September", label: "September", type: .staticText, frame: frame)
            ])
        ])

        let summary = hierarchySummary(root)

        XCTAssertEqual(summary.nodes, 4)
        XCTAssertEqual(summary.interactable, 1)
        XCTAssertEqual(summary.interactable, ScreenObservation(hierarchy: root).context.interactableCount)
    }
}
