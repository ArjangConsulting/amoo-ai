import AmooCore
import Foundation
import StudioProtocol
import Testing

/// Asynchronous run lifecycle, report persistence and REPL tokenization. Split from
/// StudioAutomationServiceTests to keep either suite readable on its own.
struct StudioAutomationRunTests {
    @Test("completed asynchronous runs expose artifacts and final status")
    func asyncCompletion() async throws {
        let executor = RecordingToolExecutor(artifacts: ["/tmp/screenshot.png"])
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: executor
        )
        let plan = StudioCompiledPlan(
            compiler: "studio",
            compilerVersion: "1",
            toolOperations: [.init(id: "operation-1", tool: "take_screenshot")]
        )
        let started = await service.start(
            .init(test: authoredTest(plan: plan), deviceId: "emulator-5554", providerId: nil)
        )

        var status = try await service.status(runId: started.runId)
        for _ in 0 ..< 100 where status.state == .running {
            try await Task.sleep(for: .milliseconds(10))
            status = try await service.status(runId: started.runId)
        }
        let report = await service.reports().reports.first

        #expect(status.state == .passed)
        #expect(status.currentOperation == 1)
        #expect(report?.artifacts == ["/tmp/screenshot.png"])
    }

    @Test("failed asynchronous runs reach a terminal status")
    func asyncFailure() async throws {
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: FailingToolExecutor()
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

        #expect(status.state == .failed)
        #expect(status.message.contains("operation-1"))
    }

    @Test("reports persist and reload from disk")
    func reportPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let reportURL = directory.appending(path: "reports.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: reportURL)
        let plan = StudioCompiledPlan(compiler: "test", compilerVersion: "1", operations: ["devices list"])

        _ = try await writer.run(.init(test: authoredTest(plan: plan), deviceId: "device", providerId: nil))
        let reader = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: reportURL)
        let reports = await reader.reports()

        #expect(reports.reports.count == 1)
        #expect(reports.reports.first?.testName == "Smoke")
        #expect(LiveStudioAutomationService.defaultReportsURL()?.lastPathComponent == "reports.json")
    }

    @Test("REPL tokenization supports single quotes and latest duplicate values")
    func replTokenization() async throws {
        let executor = RecordingToolExecutor()
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: executor
        )
        let input = StudioReplRequest(
            command: "set_text id=old ignored id='email field' value='hello world'",
            activeTest: authoredTest(),
            selectedDeviceId: "device",
            selectedProviderId: nil
        )

        _ = try await service.execute(input)
        let operation = await executor.recordedOperations().first

        #expect(operation?.arguments["id"] == "email field")
        #expect(operation?.arguments["value"] == "hello world")
        #expect(operation?.arguments["ignored"] == nil)
    }
}
