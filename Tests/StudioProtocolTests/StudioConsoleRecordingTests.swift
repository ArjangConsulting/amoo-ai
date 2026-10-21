import Foundation
@testable import StudioProtocol
import Testing

@Suite("Console recording")
struct StudioConsoleRecordingTests {
    private func makeService(
        session: FakeAgentSession,
        deviceSessions: StudioDeviceSessions = .init(),
        executor: (any StudioToolExecuting)? = nil
    ) -> LiveStudioAutomationService {
        LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: executor,
            toolCatalogProvider: AgentCatalog(),
            sessionDriver: session,
            deviceSessions: deviceSessions
        )
    }

    private func request(_ command: String, screenshot: Bool = true) -> StudioReplRequest {
        .init(
            command: command,
            activeTest: authoredTest(),
            selectedDeviceId: "sim-1",
            selectedProviderId: nil,
            platform: "ios",
            captureScreenshot: screenshot
        )
    }

    private let start = StudioReplRecordingStartRequest(
        deviceId: "sim-1",
        platform: "iOS",
        appId: "dev.app",
        testName: "Sign in"
    )

    @Test("recorded commands run in the session and report their action index and screenshot")
    func recordsCommands() async throws {
        let session = FakeAgentSession()
        let service = makeService(session: session)

        let recording = try await service.startRecording(start)
        let tap = try await service.execute(request("tap_element id=login"))
        let find = try await service.execute(request("find_elements"))

        #expect(recording.sessionId == "session-1")
        #expect(await session.specs.first == StudioSessionSpec(
            deviceId: "sim-1",
            platform: "ios",
            appId: "dev.app",
            testName: "Sign in"
        ))
        #expect(tap.actionIndex == 0)
        #expect(tap.sessionId == "session-1")
        #expect(tap.screenshot?.path == "/tmp/screen.png")
        #expect(tap.gesturePoint == StudioPoint(x: 5, y: 6))
        #expect(find.actionIndex == 1)
        #expect(find.screenshot == nil)
        #expect(await session.executed.map(\.arguments["session_id"]) == ["session-1", "session-1"])
        #expect(await session.screens == 1)
    }

    @Test("stopping ends the session, reports the plan, and frees the device")
    func stops() async throws {
        let session = FakeAgentSession()
        let devices = StudioDeviceSessions()
        let service = makeService(session: session, deviceSessions: devices)
        _ = try await service.startRecording(start)
        _ = try await service.execute(request("tap_element id=login"))

        let stopped = try await service.stopRecording(.init(deviceId: "sim-1"))

        #expect(stopped.actionCount == 1)
        #expect(stopped.planPath == "/tmp/plan.json")
        #expect(await session.ended == ["session-1"])
        #expect(await devices.owner(of: "sim-1") == nil)
        await #expect(throws: StudioAutomationError.self) {
            _ = try await service.stopRecording(.init(deviceId: "sim-1"))
        }
    }

    @Test("built-in commands are not recorded, and without a recording tools use the console's own executor")
    func unrecorded() async throws {
        let session = FakeAgentSession()
        let executor = RecordingToolExecutor()
        let service = makeService(session: session, executor: executor)

        _ = try await service.execute(request("tap_element id=login"))
        _ = try await service.startRecording(start)
        let builtin = try await service.execute(request("devices list"))

        // Unrecorded, the console's executor also takes the settled screenshot after the tap.
        #expect(await executor.operations() == ["tap_element", "take_screenshot"])
        #expect(await session.executed.isEmpty)
        #expect(builtin.actionIndex == nil)
    }

    @Test("starting again returns the current recording")
    func idempotentStart() async throws {
        let session = FakeAgentSession()
        let service = makeService(session: session)

        _ = try await service.startRecording(start)
        let again = try await service.startRecording(start)

        #expect(again.sessionId == "session-1")
        #expect(await session.specs.count == 1)
    }

    @Test("an agent run and a console recording cannot share a device")
    func exclusiveDevices() async throws {
        let session = FakeAgentSession()
        let devices = StudioDeviceSessions()
        let service = makeService(session: session, deviceSessions: devices)
        let agents = StudioAgentService(
            session: session,
            catalog: AgentCatalog(),
            deviceSessions: devices,
            modelFactory: { _ in ScriptedModel([]) }
        )

        _ = try await service.startRecording(start)

        await #expect(throws: StudioSessionError.self) { _ = try await agents.start(startRequest()) }
        _ = try await service.stopRecording(.init(deviceId: "sim-1"))
        let run = try await agents.start(startRequest())
        await agents.waitForRun(run.runId)
        #expect(await devices.owner(of: "sim-1") == nil)
    }

    @Test("a recording that fails to start frees the device")
    func failedStart() async {
        let devices = StudioDeviceSessions()
        let service = makeService(session: FakeAgentSession(startFails: true), deviceSessions: devices)

        await #expect(throws: (any Error).self) { _ = try await service.startRecording(start) }
        #expect(await devices.owner(of: "sim-1") == nil)
    }

    @Test("completion offers elements from the recording session")
    func recordedCompletion() async throws {
        let session = FakeAgentSession()
        await session.setElements([.init(id: "login", label: "Sign in", type: "button")])
        let service = makeService(session: session)
        _ = try await service.startRecording(start)

        let result = await service.complete(.init(
            line: "tap_element id=",
            cursor: 15,
            selectedDeviceId: "sim-1",
            platform: "ios"
        ))

        #expect(result.items.map(\.label) == ["login"])
        #expect(await session.executed.isEmpty)
    }

    @Test("stopping all recordings ends every session, and the capability follows the driver")
    func stopAllAndCapability() async throws {
        let session = FakeAgentSession()
        let service = makeService(session: session)
        _ = try await service.startRecording(start)

        await service.stopAllRecordings()

        #expect(await session.ended == ["session-1"])
        let handshake = Data(#"{"jsonrpc":"2.0","id":1,"method":"system.handshake"}"#.utf8)
        let response = await StudioService(workspace: AutomationWorkspace(), automation: service).handle(handshake)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let capabilities = (object["result"] as? [String: Any])?["capabilities"] as? [String]
        #expect(capabilities?.contains("repl.recording") == true)
    }
}
