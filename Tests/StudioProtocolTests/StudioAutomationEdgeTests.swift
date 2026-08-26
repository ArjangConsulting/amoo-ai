import AmooCore
import StudioProtocol
import Testing

struct StudioAutomationEdgeTests {
    @Test("REPL validates tests and handles empty workspaces")
    func replValidationAndEmptyDevices() async throws {
        let service = LiveStudioAutomationService(workspace: EdgeWorkspace(), reportsURL: nil)

        let validation = try await service.execute(repl("tests validate"))
        let devices = try await service.execute(repl("devices list"))

        #expect(validation.output.contains("is valid with 1 step"))
        #expect(devices.output == "No devices found.")
        await #expect(throws: StudioAutomationError.self) {
            try await service.execute(repl("providers inspect missing"))
        }
    }

    @Test("executor cancellation is reflected in asynchronous run status")
    func executorCancellation() async throws {
        let service = LiveStudioAutomationService(
            workspace: EdgeWorkspace(),
            reportsURL: nil,
            toolExecutor: EdgeCancellingToolExecutor()
        )
        let plan = StudioCompiledPlan(
            compiler: "studio",
            compilerVersion: "1",
            toolOperations: [.init(id: "operation-1", tool: "tap_element")]
        )
        let started = await service.start(.init(test: authoredTest(plan: plan), deviceId: "device", providerId: nil))

        var status = try await service.status(runId: started.runId)
        for _ in 0 ..< 100 where status.state == .running {
            try await Task.sleep(for: .milliseconds(10))
            status = try await service.status(runId: started.runId)
        }

        #expect(status.state == .cancelled)
        #expect(status.message == "Test run cancelled.")
    }

    private func repl(_ command: String) -> StudioReplRequest {
        .init(command: command, activeTest: authoredTest(), selectedDeviceId: nil, selectedProviderId: nil)
    }

    private func authoredTest(plan: StudioCompiledPlan? = nil) -> StudioAuthoredTest {
        .init(
            formatVersion: 1,
            name: "Smoke",
            description: "",
            platform: .android,
            steps: [.init(id: "step-1", instruction: "Inspect devices", expected: "A device is available")],
            compiledPlan: plan
        )
    }
}

private struct EdgeCancellingToolExecutor: StudioToolExecuting {
    func execute(
        _: StudioToolOperation,
        deviceId _: String,
        platform _: String,
        appId _: String?
    ) throws -> StudioToolExecutionResult {
        throw CancellationError()
    }
}

private struct EdgeWorkspace: StudioDeviceWorkspace {
    func listDevices() async -> [StudioDevice] {
        []
    }

    func startDevice(_: String) async -> StudioOperationResult {
        .init(message: "started", artifactPath: nil)
    }

    func createDevice(_: StudioCreateDeviceRequest) async -> StudioOperationResult {
        .init(
            message: "created",
            artifactPath: nil
        )
    }

    func buildInstallRun(_: StudioAppRequest) async
        -> StudioOperationResult {
        .init(message: "built", artifactPath: nil)
    }

    func reinstallRun(_: StudioAppRequest) async -> StudioOperationResult {
        .init(
            message: "installed",
            artifactPath: nil
        )
    }

    func resetData(_: StudioAppRequest) async -> StudioOperationResult {
        .init(message: "reset", artifactPath: nil)
    }
}
