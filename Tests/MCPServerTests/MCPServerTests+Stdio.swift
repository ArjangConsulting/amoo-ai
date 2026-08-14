import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

extension MCPServerTests {
    func testMCPStdioServeRespondsWithJSONRPCMessages() async throws {
        let harness = try startStdioServerHarness()
        defer {
            (harness.process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (harness.process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if harness.process.isRunning {
                harness.process.terminate()
                harness.process.waitUntilExit()
            }
        }

        let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","#
            + #""io.modelcontextprotocol/clientInfo":{"name":"amoo-tests","version":"0.0.0"},"#
            + #""io.modelcontextprotocol/clientCapabilities":{}}"#
        let messages = [
            #"{"jsonrpc":"2.0","id":"discover","method":"server/discover","params":{\#(modernMeta)}}"#,
            #"{"jsonrpc":"2.0","id":"modern-list","method":"tools/list","params":{\#(modernMeta)}}"#,
            #"{"jsonrpc":"2.0","id":"modern-call","method":"tools/call","params":{"name":"tap","#
                + #""arguments":{"x":10,"y":20},\#(modernMeta)}}"#,
            #"{"jsonrpc":"2.0","id":"unsupported","method":"tools/list","params":{"_meta":{"#
                + #""io.modelcontextprotocol/protocolVersion":"1900-01-01","#
                + #""io.modelcontextprotocol/clientCapabilities":{}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","#
                + #""capabilities":{},"clientInfo":{"name":"amoo-tests","version":"0.0.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        ].joined(separator: "\n") + "\n"
        try harness.stdin.fileHandleForWriting.write(contentsOf: Data(messages.utf8))

        let data = try await waitForStdout(harness.output) { text in
            text.contains(#""id":"discover""#)
                && text.contains(#""id":"modern-list""#)
                && text.contains(#""id":"modern-call""#)
                && text.contains(#""id":"unsupported""#)
                && text.contains(#""id":1"#)
                && text.contains(#""id":2"#)
                && text.contains("describe_screen")
        }

        let stdoutText = String(bytes: data, encoding: .utf8) ?? ""
        let lines = stdoutText.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(lines.count, 2)

        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(object?["jsonrpc"] as? String, "2.0")
        }

        XCTAssertTrue(stdoutText.contains("suggest_test_actions"))
        XCTAssertTrue(harness.errorOutput.data().isEmpty)

        let objects = try lines.compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        try assertModernJSONRPCResponses(objects)

        try harness.stdin.fileHandleForWriting.close()
        let exited = await waitForProcessExit(harness.process, timeoutNanoseconds: 5_000_000_000)
        XCTAssertTrue(exited, "MCP stdio server should exit when stdin closes")
    }

    private struct StdioServerHarness {
        let process: Process
        let stdin: Pipe
        let output: LockedDataBuffer
        let errorOutput: LockedDataBuffer
    }

    private func startStdioServerHarness() throws -> StdioServerHarness {
        let process = Process()
        process.executableURL = try amooExecutableURL()
        process.arguments = ["mcp", "serve"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let output = LockedDataBuffer()
        let errorOutput = LockedDataBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                output.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorOutput.append(data)
            }
        }

        try process.run()
        return StdioServerHarness(process: process, stdin: stdin, output: output, errorOutput: errorOutput)
    }

    private func assertModernJSONRPCResponses(_ objects: [[String: Any]]) throws {
        let discover = try XCTUnwrap(objects.first { $0["id"] as? String == "discover" })
        let discoverResult = try XCTUnwrap(
            discover["result"] as? [String: Any],
            "Unexpected discovery response: \(discover)"
        )
        XCTAssertEqual(discoverResult["resultType"] as? String, "complete")
        let supportedVersions = try XCTUnwrap(discoverResult["supportedVersions"] as? [String])
        XCTAssertEqual(supportedVersions.first, "2026-07-28")
        XCTAssertTrue(supportedVersions.contains("2025-11-25"))
        XCTAssertEqual(discoverResult["ttlMs"] as? Int, 3_600_000)

        let modernList = try XCTUnwrap(objects.first { $0["id"] as? String == "modern-list" })
        let modernListResult = try XCTUnwrap(modernList["result"] as? [String: Any])
        XCTAssertEqual(modernListResult["resultType"] as? String, "complete")
        XCTAssertEqual(modernListResult["cacheScope"] as? String, "public")
        let modernTools = try XCTUnwrap(modernListResult["tools"] as? [[String: Any]])
        let modernToolNames = modernTools.compactMap { $0["name"] as? String }
        XCTAssertEqual(modernToolNames, modernToolNames.sorted())

        let modernCall = try XCTUnwrap(objects.first { $0["id"] as? String == "modern-call" })
        let modernCallResult = try XCTUnwrap(modernCall["result"] as? [String: Any])
        XCTAssertEqual(modernCallResult["resultType"] as? String, "complete")
        XCTAssertEqual(modernCallResult["isError"] as? Bool, true)
        XCTAssertNotNil(modernCallResult["_meta"] as? [String: Any])

        let unsupported = try XCTUnwrap(objects.first { $0["id"] as? String == "unsupported" })
        let unsupportedError = try XCTUnwrap(unsupported["error"] as? [String: Any])
        XCTAssertEqual(unsupportedError["code"] as? Int, -32022)
    }
}
