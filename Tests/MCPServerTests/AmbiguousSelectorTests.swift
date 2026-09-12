// swiftlint:disable multiline_arguments
import AmooCore
import MCP
@testable import MCPServer
import XCTest

final class AmbiguousSelectorTests: XCTestCase {
    func testEmptyAndUniqueMatchesAreNotAmbiguous() async throws {
        let executor = DriverToolExecutor(driver: MockDriver())
        let empty = try await executor.uniqueElement([])
        XCTAssertNil(empty)
        let element = ElementInfo(id: "only", label: "Only")
        let unique = try await executor.uniqueElement([element])
        XCTAssertEqual(unique, element)
    }

    func testCandidatesPreferHitPointAndFallBackToFrameCentreWithoutExposingValues() async throws {
        let executor = DriverToolExecutor(driver: MockDriver())
        let elements = [
            ElementInfo(
                id: "ios-control", label: "Control", value: "private-value", type: .button,
                frame: Rect(x: 0, y: 0, width: 100, height: 100), hitPoint: Point(x: 12.5, y: 20.5)
            ),
            ElementInfo(id: "", label: "Android control", frame: Rect(x: 10, y: 20, width: 30, height: 40))
        ]
        do {
            _ = try await executor.uniqueElement(elements)
            XCTFail("Expected ambiguous selector")
        } catch let error as ToolExecutionError {
            let fields = try XCTUnwrap(error.result.structuredContent?.objectValue)
            XCTAssertEqual(fields["code"], .string("ambiguous_selector"))
            XCTAssertEqual(fields["retryable"], .bool(false))
            let candidates = try XCTUnwrap(fields["candidates"]?.arrayValue)
            XCTAssertEqual(candidates[0].objectValue?["x"], .double(12.5))
            XCTAssertEqual(candidates[0].objectValue?["y"], .double(20.5))
            XCTAssertEqual(candidates[1].objectValue?["x"], .double(25))
            XCTAssertEqual(candidates[1].objectValue?["y"], .double(40))
            XCTAssertNil(candidates[0].objectValue?["value"])
            XCTAssertFalse(error.message.contains("private-value"))
        }
    }

    func testLargeAmbiguousResultsAreBoundedAndAllowMissingGeometry() async throws {
        let executor = DriverToolExecutor(driver: MockDriver())
        let elements = (0 ..< 12).map { ElementInfo(id: "item-\($0)", label: "Item") }
        do {
            _ = try await executor.uniqueElement(elements)
            XCTFail("Expected ambiguous selector")
        } catch let error as ToolExecutionError {
            let candidates = try XCTUnwrap(error.result.structuredContent?.objectValue?["candidates"]?.arrayValue)
            XCTAssertEqual(candidates.count, 8)
            XCTAssertNil(candidates[0].objectValue?["x"])
            XCTAssertTrue(error.message.contains("12 elements"))
            XCTAssertFalse(error.message.contains("item-8"))
        }
    }
}

// swiftlint:enable multiline_arguments
