import Foundation
@testable import MCPServer
import XCTest

final class MCPRequestRuntimeTests: XCTestCase {
    func testSmallRequestArrivesBeforeWriterCloses() async throws {
        let pipe = Pipe()
        let received = expectation(description: "small request delivered with input still open")
        let payload = Data("request\n".utf8)
        let reader = Task {
            for try await data in MCPRequestRuntime.input(pipe.fileHandleForReading) {
                XCTAssertEqual(data, payload)
                received.fulfill()
                break
            }
        }
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        await fulfillment(of: [received], timeout: 2)
        try pipe.fileHandleForWriting.close()
        try await reader.value
    }
}
