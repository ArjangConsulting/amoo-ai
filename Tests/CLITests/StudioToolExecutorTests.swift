@testable import CLI
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
}
