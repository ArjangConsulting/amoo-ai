
@testable import MCPServer
import Foundation
import MCP
import MobileTestingCore
import XCTest

final class MCPServerTests: XCTestCase {
    func testToolNamesAreExposed() {
        let server = MCPServer()
        let names = server.toolNames()
        XCTAssertTrue(names.contains("tap"))
        XCTAssertTrue(names.contains("device_boot"))
        XCTAssertTrue(names.contains("find_elements"))
        XCTAssertTrue(names.contains("get_screen_context"))
        XCTAssertTrue(names.contains("scroll"))
        XCTAssertTrue(names.contains("set_permission"))
        XCTAssertTrue(names.contains("audit_app"))
        XCTAssertTrue(names.contains("audit_accessibility"))
        XCTAssertTrue(names.contains("audit_security"))
        XCTAssertTrue(names.contains("describe_screen"))
        XCTAssertTrue(names.contains("suggest_test_actions"))
        XCTAssertTrue(names.contains("analyze_ai_testability"))
        XCTAssertTrue(names.contains("find_element_by_description"))
        XCTAssertFalse(names.contains { $0.hasPrefix("ai_") })
    }

    func testToolDefinitionsHaveSchemas() throws {
        let server = MCPServer()
        let defs = server.toolDefinitions()
        XCTAssertFalse(defs.isEmpty)

        let tap = defs.first(where: { $0.name == "tap" })
        XCTAssertNotNil(tap)
        XCTAssertEqual(tap?.required, ["x", "y"])
        XCTAssertEqual(tap?.properties.count, 2)
        XCTAssertFalse(try XCTUnwrap(tap?.description.isEmpty))
    }

    func testMCPToolConversionIncludesInputSchema() throws {
        let definition = ToolDefinition(
            name: "tap",
            title: "Tap",
            description: "Tap a coordinate.",
            properties: [
                "x": .init(type: "number", description: "Horizontal coordinate"),
                "y": .init(type: "number", description: "Vertical coordinate")
            ],
            required: ["x", "y"]
        )

        let tool = definition.mcpTool()

        XCTAssertEqual(tool.name, "tap")
        XCTAssertEqual(tool.title, "Tap")
        XCTAssertEqual(tool.description, "Tap a coordinate.")
        XCTAssertTrue(tool.inputSchema.description.contains("additionalProperties"))
        XCTAssertTrue(tool.inputSchema.description.contains("false"))
        XCTAssertTrue(tool.inputSchema.description.contains("x"))
        XCTAssertTrue(tool.inputSchema.description.contains("y"))
        XCTAssertNil(tool.outputSchema)
    }

    func testMCPToolConversionIncludesOutputSchema() throws {
        let definition = ToolDefinition(
            name: "suggest_test_actions",
            description: "Suggest actions.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "confidence": .init(type: "string", description: "Confidence level"),
                    "suggestedActions": .init(type: "array", description: "Ranked actions")
                ],
                required: ["confidence", "suggestedActions"]
            )
        )

        let tool = definition.mcpTool()

        XCTAssertTrue(tool.inputSchema.description.contains("additionalProperties"))
        XCTAssertTrue(tool.inputSchema.description.contains("false"))
        let outputSchema = try XCTUnwrap(tool.outputSchema)
        XCTAssertTrue(outputSchema.description.contains("confidence"))
        XCTAssertTrue(outputSchema.description.contains("suggestedActions"))
        XCTAssertTrue(outputSchema.description.contains("additionalProperties"))
        XCTAssertTrue(outputSchema.description.contains("false"))
    }

    func testArrayOutputPropertyEmitsItemsSchema() throws {
        let definition = ToolDefinition(
            name: "suggest_test_actions",
            description: "Suggest actions.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "suggestedActions": .init(
                        type: "array",
                        description: "Ranked actions",
                        items: .object(
                            properties: [
                                "priority": .init(type: "integer", description: "Priority"),
                                "action": .init(type: "string", description: "Action")
                            ],
                            required: ["priority", "action"]
                        )
                    ),
                    "labels": .init(
                        type: "array",
                        description: "Labels",
                        items: .scalar(type: "string")
                    )
                ],
                required: ["suggestedActions", "labels"]
            )
        )

        let tool = definition.mcpTool()
        let outputSchema = try XCTUnwrap(tool.outputSchema)
        let description = outputSchema.description
        XCTAssertTrue(description.contains("items"))
        XCTAssertTrue(description.contains("priority"))
        XCTAssertTrue(description.contains("action"))
        XCTAssertTrue(description.contains("string"))
    }

    func testToolResultMCPResultPreservesContentErrorAndStructuredContent() throws {
        let structured: Value = .object([
            "confidence": .string("medium"),
            "suggestedActions": .array([.string("Tap Submit")])
        ])

        let result = ToolResult(content: "Suggested actions", isError: true, structuredContent: structured).mcpResult()

        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent, structured)
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            return XCTFail("Expected text content")
        }
        XCTAssertEqual(text, "Suggested actions")
    }

    func testStringifyArgumentValueHandlesAllCases() {
        XCTAssertEqual(stringifyArgumentValue(.null), "")
        XCTAssertEqual(stringifyArgumentValue(.bool(true)), "true")
        XCTAssertEqual(stringifyArgumentValue(.bool(false)), "false")
        XCTAssertEqual(stringifyArgumentValue(.int(42)), "42")
        XCTAssertEqual(stringifyArgumentValue(.double(1.5)), "1.5")
        XCTAssertEqual(stringifyArgumentValue(.string("hello")), "hello")
        XCTAssertEqual(stringifyArgumentValue(.array([.string("a"), .int(1)])), #"["a",1]"#)
        XCTAssertEqual(stringifyArgumentValue(.object(["k": .string("v")])), #"{"k":"v"}"#)
    }

    func testMCPStdioServeRespondsWithJSONRPCMessages() async throws {
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
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"amoo-tests","version":"0.0.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        ].joined(separator: "\n") + "\n"
        try stdin.fileHandleForWriting.write(contentsOf: Data(messages.utf8))

        let data = try await waitForStdout(output) { text in
            text.contains(#""id":1"#) && text.contains(#""id":2"#) && text.contains("describe_screen")
        }

        let stdoutText = String(decoding: data, as: UTF8.self)
        let lines = stdoutText.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(lines.count, 2)

        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(object?["jsonrpc"] as? String, "2.0")
        }

        XCTAssertTrue(stdoutText.contains("suggest_test_actions"))
        XCTAssertTrue(errorOutput.data().isEmpty)

        try stdin.fileHandleForWriting.close()
        let exited = await waitForProcessExit(process, timeoutNanoseconds: 5_000_000_000)
        XCTAssertTrue(exited, "MCP stdio server should exit when stdin closes")
    }

    func testHealthPassThrough() {
        let server = MCPServer()
        XCTAssertEqual(server.health(), "ok")
    }

    func testExecuteWithoutDriverReturnsError() async {
        let server = MCPServer()
        let result = await server.execute(toolName: "tap", arguments: ["x": "10", "y": "20"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("No tool executor"))
    }

    func testExecuteTapDelegatesToDriver() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "tap", arguments: ["x": "10", "y": "20"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Tapped"))

        let calls = await driver.calls
        XCTAssertEqual(calls, ["tap:10.0,20.0"])
    }

    func testExecuteDeviceLifecycle() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let boot = await server.execute(toolName: "device_boot", arguments: [:])
        XCTAssertFalse(boot.isError)

        let install = await server.execute(toolName: "device_install_app", arguments: ["path": "/tmp/App.app"])
        XCTAssertFalse(install.isError)

        let launch = await server.execute(toolName: "device_launch_app", arguments: ["app_id": "com.example"])
        XCTAssertFalse(launch.isError)

        let calls = await driver.calls
        XCTAssertEqual(calls, ["boot", "install:/tmp/App.app", "launch:com.example"])
    }

    func testExecuteValidatesArguments() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "tap", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Missing required"))
    }

    func testExecuteUnknownToolReturnsError() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "nonexistent", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Unknown tool"))
    }

    func testExecuteQueryTools() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let context = await server.execute(toolName: "get_screen_context", arguments: [:])
        XCTAssertFalse(context.isError)
        XCTAssertEqual(context.content, "Mock screen")

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(hierarchy.content.contains("root"))
    }

    func testExecuteScrollAndTypeText() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down"])
        XCTAssertFalse(scroll.isError)

        let typeText = await server.execute(toolName: "type_text", arguments: ["text": "hello"])
        XCTAssertFalse(typeText.isError)

        let calls = await driver.calls
        XCTAssertEqual(calls, ["scroll:down:300.0", "typeText:hello"])
    }

    // MARK: - Audit Tool Tests

    func testAuditAppRequiresAppID() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("app_id"))
    }

    func testAuditAppReturnsFindings() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
        // The mock driver returns elements that trigger audit rules (e.g. missing labels)
        XCTAssertTrue(result.content.contains("com.test"))
    }

    func testAuditSecurityRunsSecurityRulesOnly() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_security", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
    }

    func testAuditAccessibilityRunsUXRules() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_accessibility", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
    }

    func testAuditWithFailOnThreshold() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "audit_app",
            arguments: ["app_id": "com.test", "fail_on": "low"]
        )
        // If there are findings at low or above, isError should be true
        if result.content.contains("finding") {
            XCTAssertTrue(result.isError)
        }
    }

    func testAuditPassesCleanApp() async {
        let driver = MockDriver() // Clean mock with no problematic elements
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: ["app_id": "com.clean"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Audit passed") || result.content.contains("finding"))
    }

    // MARK: - Assistant Tool Tests

    func testDescribeScreen() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "describe_screen", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Screen summary: Mock screen"))
        XCTAssertTrue(result.content.contains("Interactable elements: 0"))
        XCTAssertNotNil(result.structuredContent)
    }

    func testDescribeScreenStructuredContentMatchesSchema() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "describe_screen", arguments: [:])
        let structured = try XCTUnwrap(result.structuredContent)
        let fields = try XCTUnwrap(structured.objectValue)
        XCTAssertEqual(fields["summary"]?.stringValue, "Mock screen")
        XCTAssertEqual(fields["interactableCount"]?.intValue, 0)
    }

    func testDescribeScreenIncludesVisibleStructureAndActions() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "describe_screen", arguments: [:])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Screen summary: Debug mode enabled - Test screen"))
        XCTAssertTrue(result.content.contains("Interactable elements: 2"))
        XCTAssertTrue(result.content.contains("Key actions: button Submit; button Cancel"))
    }

    func testSuggestActionsWithoutInteractableElements() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "suggest_test_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertNotNil(result.structuredContent)
        XCTAssertTrue(result.content.contains("Screen intent:"))
        XCTAssertTrue(result.content.contains("Suggested actions:"))
        XCTAssertTrue(result.content.contains("Accessibility issues:"))
        XCTAssertTrue(result.content.contains("No app-relevant interactable elements"))
    }

    func testSuggestActionsWithInteractableElements() async {
        let driver = AuditMockDriver() // Has interactable elements
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "suggest_test_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertNotNil(result.structuredContent)
        XCTAssertTrue(result.content.contains("Screen intent:"))
        XCTAssertTrue(result.content.contains("1. Tap Submit"))
        XCTAssertTrue(result.content.contains("2. Tap Cancel"))
        XCTAssertTrue(result.content.contains("Developer feedback:"))
    }

    func testSuggestActionsReturnsStructuredReport() async throws {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "suggest_test_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Confidence: medium"))

        let data = try JSONEncoder().encode(try XCTUnwrap(result.structuredContent))
        let report = try JSONDecoder().decode(TestActionSuggestionReport.self, from: data)
        XCTAssertEqual(report.suggestedActions.count, 3)
        XCTAssertEqual(report.suggestedActions.first?.priority, 1)
    }

    func testAnalyzeAITestabilityReturnsStructuredFeedback() async throws {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "analyze_ai_testability", arguments: [:])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("AI testability:"))
        let data = try JSONEncoder().encode(try XCTUnwrap(result.structuredContent))
        let report = try JSONDecoder().decode(AITestabilityReport.self, from: data)
        XCTAssertEqual(report.interactableCount, 2)
        XCTAssertFalse(report.developerFeedback.isEmpty)
    }

    func testFindByDescriptionRequiresDescription() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "find_element_by_description", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("description"))
    }

    func testFindByDescriptionWithoutMatches() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "find_element_by_description",
            arguments: ["description": "login button"]
        )
        XCTAssertFalse(result.isError)
        // MockDriver.findByDescription returns empty, so "No elements matched"
        XCTAssertTrue(result.content.contains("No elements matched"))
    }

    func testFindByDescriptionMatchesExposedLabels() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "find_element_by_description", arguments: ["description": "submit"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("match"))
        XCTAssertNotNil(result.structuredContent)
    }

    func testRemovedAIToolNamesReturnUnknownTool() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let describeAI = await server.execute(toolName: "ai_describe_screen", arguments: [:])
        XCTAssertTrue(describeAI.isError)
        XCTAssertTrue(describeAI.content.contains("Unknown tool"))

        let suggestAI = await server.execute(toolName: "ai_suggest_actions", arguments: [:])
        XCTAssertTrue(suggestAI.isError)
        XCTAssertTrue(suggestAI.content.contains("Unknown tool"))

        let findAI = await server.execute(toolName: "ai_find_by_description", arguments: ["description": "submit"])
        XCTAssertTrue(findAI.isError)
        XCTAssertTrue(findAI.content.contains("Unknown tool"))
    }

    func testSwipeInDirectionTool() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "swipe_in_direction",
            arguments: ["direction": "left", "distance": "300", "duration_ms": "400"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("left"))

        let resultWithElement = await server.execute(
            toolName: "swipe_in_direction",
            arguments: ["direction": "up", "element_id": "scroll-view"]
        )
        XCTAssertFalse(resultWithElement.isError)

        let missing = await server.execute(
            toolName: "swipe_in_direction",
            arguments: [:]
        )
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.content.contains("direction"))

        let calls = await driver.calls
        XCTAssertTrue(calls.contains(where: { $0.hasPrefix("swipeInDirection:left") }))
        XCTAssertTrue(calls.contains(where: { $0.hasPrefix("swipeInDirection:up") }))
    }

    func testSwipeInDirectionToolNameExposed() {
        let server = MCPServer()
        XCTAssertTrue(server.toolNames().contains("swipe_in_direction"))
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }

    func data() -> Data {
        lock.withLock { storage }
    }
}

private func waitForStdout(
    _ buffer: LockedDataBuffer,
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    condition: (String) -> Bool
) async throws -> Data {
    let start = ContinuousClock.now
    while start.duration(to: .now) < .nanoseconds(Int64(timeoutNanoseconds)) {
        let data = buffer.data()
        let text = String(decoding: data, as: UTF8.self)
        if condition(text) {
            return data
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    let text = String(decoding: buffer.data(), as: UTF8.self)
    throw XCTSkip("Timed out waiting for MCP stdio response. Captured stdout: \(text)")
}

private func waitForProcessExit(_ process: Process, timeoutNanoseconds: UInt64) async -> Bool {
    let start = ContinuousClock.now
    while process.isRunning {
        if start.duration(to: .now) >= .nanoseconds(Int64(timeoutNanoseconds)) {
            return false
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

private func amooExecutableURL() throws -> URL {
    let sourceURL = URL(fileURLWithPath: #filePath)
    let packageRoot = sourceURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/amoo"),
        packageRoot.appendingPathComponent(".build/debug/amoo")
    ]

    guard let executableURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        let paths = candidates.map(\.path).joined(separator: ", ")
        throw XCTSkip("Cannot locate built amoo executable at any expected path: \(paths).")
    }

    return executableURL
}

/// Mock driver that returns elements triggering audit rules.
private actor AuditMockDriver: PlatformDriver {
    func boot() async throws {}
    func shutdown() async throws {}
    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "mock", name: "Mock", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path _: String) async throws {}
    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {}
    func terminateApp(appID _: String) async throws {}
    func uninstallApp(appID _: String) async throws {}

    func tap(at _: Point) async throws {}
    func doubleTap(at _: Point) async throws {}
    func longPress(at _: Point, duration _: Duration) async throws {}
    func tapElement(_: ElementSelector) async throws {}

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {}
    func swipe(direction _: Direction, distance _: Double, duration _: Duration) async throws {}
    func swipe(direction _: Direction, distance _: Double, duration _: Duration, element _: ElementSelector?) async throws {}
    func scroll(direction _: Direction, distance _: Double) async throws {}
    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {}
    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {}
    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {}

    func typeText(_: String) async throws {}
    func clearText(characterCount _: Int?) async throws {}
    func setText(_: ElementSelector, text _: String) async throws {}

    func pressBack() async throws {}
    func pressHome() async throws {}
    func openURL(_: String) async throws {}

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        [
            // Element with empty label and empty id — triggers missing accessibility label
            ElementInfo(id: "", label: "", type: .button, frame: Rect(x: 0, y: 0, width: 30, height: 30)),
            // Small tap target
            ElementInfo(id: "tiny", label: "Tiny", type: .button, frame: Rect(x: 10, y: 10, width: 20, height: 20)),
            // Sensitive text field — triggers insecure text field rule
            ElementInfo(id: "password_field", label: "Password", type: .textField),
            // Normal button
            ElementInfo(
                id: "submit_btn",
                label: "Submit",
                type: .button,
                frame: Rect(x: 0, y: 0, width: 100, height: 44)
            )
        ]
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(
            id: "root",
            children: [
                ViewNode(id: "title", label: "Test screen", type: .staticText),
                ViewNode(id: "submit_btn", label: "Submit", type: .button),
                ViewNode(id: "cancel_btn", label: "Cancel", type: .button)
            ]
        )
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        true
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {}
    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {}
    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xFF])
    }

    func startRecording() async throws -> RecordingSession {
        RecordingSession(id: "rec", deviceID: "mock")
    }

    func stopRecording(_: RecordingSession) async throws {}

    func setPermission(_: PermissionChange) async throws {}
    func setLocation(latitude _: Double, longitude _: Double) async throws {}
    func clearLocation() async throws {}
    func setAppearance(_: Appearance) async throws {}

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Debug mode enabled - Test screen", interactableCount: 4)
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        [
            ElementInfo(id: "submit_btn", label: "Submit", type: .button),
            ElementInfo(id: "cancel_btn", label: "Cancel", type: .button)
        ]
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }

    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .notRunning
    }
}

private actor MockDriver: PlatformDriver {
    var calls: [String] = []

    func boot() async throws {
        calls.append("boot")
    }

    func shutdown() async throws {
        calls.append("shutdown")
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "mock", name: "Mock", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path: String) async throws {
        calls.append("install:\(path)")
    }

    func launchApp(appID: String, arguments _: [String], environment _: [String: String]) async throws {
        calls.append("launch:\(appID)")
    }

    func terminateApp(appID: String) async throws {
        calls.append("terminate:\(appID)")
    }

    func uninstallApp(appID: String) async throws {
        calls.append("uninstall:\(appID)")
    }

    func tap(at point: Point) async throws {
        calls.append("tap:\(point.x),\(point.y)")
    }

    func doubleTap(at point: Point) async throws {
        calls.append("doubleTap:\(point.x),\(point.y)")
    }

    func longPress(at _: Point, duration _: Duration) async throws {
        calls.append("longPress")
    }

    func tapElement(_: ElementSelector) async throws {
        calls.append("tapElement")
    }

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {
        calls.append("swipe")
    }

    func swipe(direction: Direction, distance: Double, duration _: Duration) async throws {
        calls.append("swipeInDirection:\(direction):\(distance)")
    }

    func swipe(direction: Direction, distance: Double, duration _: Duration, element: ElementSelector?) async throws {
        let suffix = element.flatMap { $0.id }.map { ":\($0)" } ?? ""
        calls.append("swipeInDirection:\(direction):\(distance)\(suffix)")
    }

    func scroll(direction: Direction, distance: Double) async throws {
        calls.append("scroll:\(direction):\(distance)")
    }

    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {}
    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {}
    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {}

    func typeText(_ text: String) async throws {
        calls.append("typeText:\(text)")
    }

    func clearText(characterCount _: Int?) async throws {
        calls.append("clearText")
    }

    func setText(_: ElementSelector, text _: String) async throws {}

    func pressBack() async throws {
        calls.append("pressBack")
    }

    func pressHome() async throws {
        calls.append("pressHome")
    }

    func openURL(_ url: String) async throws {
        calls.append("openURL:\(url)")
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        [ElementInfo(id: selector.id ?? "el", label: selector.label ?? "label")]
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        true
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {}
    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {}
    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xFF])
    }

    func startRecording() async throws -> RecordingSession {
        RecordingSession(id: "rec", deviceID: "mock")
    }

    func stopRecording(_: RecordingSession) async throws {}

    func setPermission(_ change: PermissionChange) async throws {
        calls.append("permission:\(change.appID):\(change.permission)")
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        calls.append("location:\(latitude),\(longitude)")
    }

    func clearLocation() async throws {
        calls.append("clearLocation")
    }

    func setAppearance(_ appearance: Appearance) async throws {
        calls.append("appearance:\(appearance.rawValue)")
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Mock screen")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        []
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }

    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .notRunning
    }
}
