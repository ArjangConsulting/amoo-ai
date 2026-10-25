// swiftlint:disable multiline_arguments
import AmooCore
import XCTest

final class SemanticObservationTests: XCTestCase {
    func testSelectionAndRawStateChangesAffectTheObservationToken() {
        let initial = ViewNode(id: "option", label: "Second", type: .button, isSelected: false)
        var selected = initial
        selected.isSelected = true
        let before = ScreenObservation(hierarchy: initial)
        let after = ScreenObservation(hierarchy: selected)
        XCTAssertNotEqual(before.token, after.token)
        XCTAssertEqual(after.elements.first?.isSelected, true)
        var checked = initial
        checked.semantics = ElementSemantics(attributes: ["checked": "true", "stateDescription": "Copied"])
        XCTAssertNotEqual(before.token, ScreenObservation(hierarchy: checked).token)
    }

    func testCaptureIdentityDoesNotCreateAFalseScreenChange() {
        let first = ViewNode(id: "option", semantics: ElementSemantics(reference: "capture-one:0"))
        var second = first
        second.semantics?.reference = "capture-two:0"
        XCTAssertEqual(ScreenObservation(hierarchy: first).token, ScreenObservation(hierarchy: second).token)
    }

    func testClickableGenericAndroidNodesRemainInteractableAndRetainRelationships() {
        let node = ViewNode(id: "", semantics: ElementSemantics(
            reference: "capture:0/1", parentReference: "capture:0", hierarchyPath: "0/1",
            attributes: ["clickable": "true"]
        ))
        let observation = ScreenObservation(hierarchy: node)
        XCTAssertEqual(observation.interactableElements.count, 1)
        XCTAssertEqual(observation.elements.first?.semantics?.parentReference, "capture:0")
    }
}

// swiftlint:enable multiline_arguments
