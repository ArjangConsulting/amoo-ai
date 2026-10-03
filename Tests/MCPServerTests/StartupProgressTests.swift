import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestCommons
import XCTest

final class StartupProgressTests: XCTestCase {
    func testWireProgressPrecedesResultAndKeepsTokenAndMonotonicCounter() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let input = scratch.url.appending(path: "input.jsonl")
        let output = scratch.url.appending(path: "output.jsonl")
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_devices","arguments":{},"#
                + #""_meta":{"progressToken":"startup-2"}}}"#
        ]
        try Data((messages.joined(separator: "\n") + "\n").utf8).write(to: input)
        try Data().write(to: output)
        let reader = try FileHandle(forReadingFrom: input)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? reader.close(); try? writer.close() }
        let server = MCPStdioServer(server: MCPServer(executor: StartupTestExecutor()))
        try await server.run(input: reader, output: writer)
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        let objects = try lines.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let progress = objects.filter { $0["method"] as? String == "notifications/progress" }
        XCTAssertEqual(progress.count, 2)
        let params = try progress.map { try XCTUnwrap($0["params"] as? [String: Any]) }
        XCTAssertEqual(params.compactMap { $0["progressToken"] as? String }, ["startup-2", "startup-2"])
        XCTAssertEqual(params.compactMap { $0["progress"] as? Int }, [1, 2])
        XCTAssertEqual(params.compactMap { $0["message"] as? String }, ["Booting simulator", "Launching companion"])
        XCTAssertEqual(objects.last?["id"] as? Int, 2)
    }

    func testPollableStatusTracksPendingStagesAndFailure() async {
        let operation = StartupOperation(id: "request")
        await StartupProgress.$startup.withValue(operation) {
            await StartupProgress.report("Booting simulator")
            await StartupProgress.report("Building companion")
        }
        let pending = await operation.summary()
        XCTAssertTrue(pending.contains("starting"))
        XCTAssertTrue(pending.contains("Booting simulator"))
        XCTAssertTrue(pending.contains("Building companion"))
        await operation.finish(success: false)
        let failed = await operation.summary()
        XCTAssertTrue(failed.contains("failed"))
    }
}

private struct StartupTestExecutor: ToolExecutor {
    func execute(toolName _: String, arguments _: [String: String]) async -> ToolResult {
        await StartupProgress.report("Booting simulator")
        await StartupProgress.report("Launching companion")
        return .success("ready")
    }
}
