import AmooCore
@testable import MCPServer
import XCTest

final class TapOcclusionClippingTests: XCTestCase {
    private let target = ElementInfo(
        id: "tab", label: "Items", type: .button, frame: Rect(x: 20, y: 80, width: 120, height: 40)
    )

    func testScrolledContentCannotCoverATargetOutsideItsViewport() {
        for type: ElementType in [.scrollView, .table, .collectionView] {
            let root = screen(containerType: type, viewportTop: 120)

            XCTAssertNil(TapHittability.block(for: target, at: Point(x: 80, y: 100), in: root))
        }
    }

    func testContentStillCoversATargetInsideItsViewport() {
        let root = screen(containerType: .scrollView, viewportTop: 60)

        XCTAssertEqual(
            TapHittability.block(for: target, at: Point(x: 80, y: 100), in: root),
            .covered(by: "button 'row'")
        )
    }

    func testOuterViewportClipsContentThroughAnIntermediateContainer() {
        let root = screen(containerType: .scrollView, viewportTop: 120, nested: true)

        XCTAssertNil(TapHittability.block(for: target, at: Point(x: 80, y: 100), in: root))
    }

    func testUnclippedSiblingOverlayStillCoversTheTarget() {
        var root = screen(containerType: .scrollView, viewportTop: 120)
        root.children.append(ViewNode(id: "overlay", type: .button, frame: target.frame))

        XCTAssertEqual(
            TapHittability.block(for: target, at: Point(x: 80, y: 100), in: root),
            .covered(by: "button 'overlay'")
        )
    }

    private func screen(containerType: ElementType, viewportTop: Double, nested: Bool = false) -> ViewNode {
        let row = ViewNode(id: "row", type: .button, frame: Rect(x: 0, y: 60, width: 390, height: 160))
        let content = nested ? ViewNode(id: "content", type: .other, children: [row]) : row
        let viewport = ViewNode(
            id: "viewport",
            type: containerType,
            frame: Rect(x: 0, y: viewportTop, width: 390, height: 500),
            children: [content]
        )
        return ViewNode(
            id: "root",
            type: .other,
            frame: Rect(x: 0, y: 0, width: 390, height: 844),
            children: [ViewNode(id: target.id, label: target.label, type: .button, frame: target.frame), viewport]
        )
    }
}
