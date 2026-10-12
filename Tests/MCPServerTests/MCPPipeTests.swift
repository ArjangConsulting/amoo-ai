import Foundation
@testable import MCPServer
import XCTest

final class MCPPipeTests: XCTestCase {
    func testBlockedOutputDoesNotBlockCancellation() async throws {
        let pipe = Pipe()
        let runtime = MCPRequestRuntime(output: pipe.fileHandleForWriting)
        let started = expectation(description: "request started")
        let cancelled = expectation(description: "request cancelled")
        let accepted = await runtime.submit(id: "slow") {
            started.fulfill()
            do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.fulfill() }
            return nil
        }
        XCTAssertTrue(accepted)
        await fulfillment(of: [started], timeout: 1)
        let size = 1_048_576
        let writer = Task { await runtime.write(Data(repeating: 65, count: size)) }
        await runtime.cancel(id: "slow")
        await fulfillment(of: [cancelled], timeout: 1)
        let read = expectation(description: "response drained")
        DispatchQueue.global().async {
            var bytes = 0
            while bytes < size {
                bytes += pipe.fileHandleForReading.availableData.count
            }
            read.fulfill()
        }
        await writer.value
        await fulfillment(of: [read], timeout: 2)
        try pipe.fileHandleForWriting.close()
        try pipe.fileHandleForReading.close()
    }

    func testStoppingLifetimeWakesInputWithWriterStillOpen() async throws {
        let pipe = Pipe()
        let lifetime = MCPPipeLifetime()
        let reader = Task {
            for try await _ in mcpInput(pipe.fileHandleForReading, lifetime: lifetime) {
                XCTFail("No request was sent")
            }
        }
        lifetime.stop()
        try await reader.value
        try pipe.fileHandleForWriting.close()
        try pipe.fileHandleForReading.close()
    }
}
