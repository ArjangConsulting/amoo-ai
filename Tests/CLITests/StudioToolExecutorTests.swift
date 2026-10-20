@testable import CLI
import MCPServer
import StudioProtocol
import Testing

struct StudioToolExecutorTests {
    @Test("Studio tool execution rejects unsupported platforms before connecting")
    func unsupportedPlatform() async {
        let executor = CLIStudioToolExecutor()
        let operation = StudioToolOperation(id: "operation-1", tool: "take_screenshot")

        do {
            _ = try await executor.execute(operation, deviceId: "device", platform: "Web", appId: nil)
            Issue.record("Expected an unsupported-platform error.")
        } catch let error as StudioToolExecutorError {
            #expect(error.description == "Unsupported test platform: Web")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Studio tool failures preserve their actionable message")
    func toolFailureDescription() {
        let error = StudioToolExecutorError.toolFailed("Element was not found")
        #expect(error.description == "Element was not found")
    }

    @Test("plan-only vocabulary runs as the MCP tools the compiler records it from")
    func planVocabularyTranslation() {
        let absent = CLIStudioToolExecutor.mcpCall(for: .init(
            id: "1",
            tool: "assert_not_visible",
            arguments: ["id": "spinner"]
        ))
        let wait = CLIStudioToolExecutor.mcpCall(for: .init(
            id: "2",
            tool: "wait_for_element",
            arguments: ["id": "home", "timeout_ms": "5000"]
        ))
        let textWithSelector = CLIStudioToolExecutor.mcpCall(for: .init(
            id: "3",
            tool: "assert_text",
            arguments: ["id": "title", "expected": "Welcome"]
        ))
        let textAlone = CLIStudioToolExecutor.mcpCall(for: .init(
            id: "4",
            tool: "assert_text",
            arguments: ["expected": "Welcome"]
        ))
        let passthrough = CLIStudioToolExecutor.mcpCall(for: .init(
            id: "5",
            tool: "tap_element",
            arguments: ["id": "login"]
        ))

        #expect(absent.tool == "assert_absent")
        #expect(absent.arguments == ["id": "spinner"])
        #expect(wait.tool == "assert_visible")
        #expect(wait.arguments == ["id": "home", "timeout_ms": "5000"])
        #expect(textWithSelector.tool == "assert_visible")
        #expect(textWithSelector.arguments == ["id": "title", "label": "Welcome"])
        #expect(textAlone.arguments == ["contains_text": "Welcome"])
        #expect(passthrough.tool == "tap_element")
    }

    @Test("the Studio catalog mirrors the MCP registry with Studio's console rules")
    func catalogFromRegistry() throws {
        let tools = Dictionary(uniqueKeysWithValues: MCPStudioToolCatalog().tools().map { ($0.name, $0) })
        let swipe = try #require(tools["swipe_in_direction"])
        let tap = try #require(tools["tap_element"])

        #expect(swipe.arguments.first?.name == "direction")
        #expect(swipe.arguments.first?.values == ["up", "down", "left", "right"])
        #expect(swipe.planTool == "swipe_in_direction")
        #expect(!tap.arguments.contains { $0.name == "session_id" })
        #expect(tools["assert_absent"]?.planTool == "assert_not_visible")
        #expect(tools["start_session"]?.replSupported == false)
        #expect(tools["companion_status"]?.replSupported == false)
        #expect(tools["device_uninstall_app"]?.destructive == true)
        #expect(tools["find_elements"]?.readOnly == true)
        #expect(tools["tap_element"]?.readOnly == false)
        #expect(tools["assert_visible"]?.category == "assertion")
        #expect(tools.values.allSatisfy { $0.category != "other" })
    }

    @Test("MCP schemas publish exhaustive values as enum, open ones as examples, and annotations")
    func mcpSchemaHints() throws {
        let definitions = Dictionary(uniqueKeysWithValues: MCPServer().toolDefinitions().map { ($0.name, $0) })
        let swipe = try #require(definitions["swipe_in_direction"]).mcpTool()
        let key = try #require(definitions["press_key"]).mcpTool()
        let uninstall = try #require(definitions["device_uninstall_app"]).mcpTool()
        let find = try #require(definitions["find_elements"]).mcpTool()

        #expect(swipe.inputSchema.description.contains("enum"))
        #expect(key.inputSchema.description.contains("examples"))
        #expect(!key.inputSchema.description.contains("enum"))
        #expect(uninstall.annotations.destructiveHint == true)
        #expect(find.annotations.readOnlyHint == true)
        #expect(find.annotations.destructiveHint == nil)
    }
}
