import Foundation
import StudioProtocol
import Testing

@Suite("Studio transport")
struct StudioTransportTests {
    @Test("a health check answers while a slow request is still running")
    func concurrentRequests() async throws {
        let gate = Gate()
        let harness = TransportHarness(workspace: GatedWorkspace(gate: gate))
        let params = #"{"deviceId":"sim-1","appId":"dev.app"}"#
        try harness.send(#"{"jsonrpc":"2.0","id":1,"method":"apps.buildInstallRun","params":"# + params + "}")
        try harness.send(#"{"jsonrpc":"2.0","id":2,"method":"system.health"}"#)

        let first = try await harness.nextFrame()
        await gate.open()
        let second = try await harness.nextFrame()

        #expect(first["id"] as? Int == 2)
        #expect(second["id"] as? Int == 1)
        await harness.finish()
    }

    @Test("posted notifications are framed without an id")
    func notificationFraming() async throws {
        let harness = TransportHarness(workspace: GatedWorkspace(gate: Gate(isOpen: true)))
        try harness.send(#"{"jsonrpc":"2.0","id":1,"method":"system.health"}"#)
        _ = try await harness.nextFrame()

        await harness.service.notifications.post(method: "agent.event", params: ["seq": 3])
        let frame = try await harness.nextFrame()

        #expect(frame["jsonrpc"] as? String == "2.0")
        #expect(frame["method"] as? String == "agent.event")
        #expect((frame["params"] as? [String: Any])?["seq"] as? Int == 3)
        #expect(frame.keys.contains("id") == false)
        await harness.finish()
    }

    @Test("client notifications run without a response")
    func clientNotification() async throws {
        let harness = TransportHarness(workspace: GatedWorkspace(gate: Gate(isOpen: true)))
        try harness.send(#"{"jsonrpc":"2.0","method":"system.health"}"#)
        try harness.send(#"{"jsonrpc":"2.0","id":7,"method":"system.health"}"#)

        let frame = try await harness.nextFrame()

        #expect(frame["id"] as? Int == 7)
        await harness.finish()
    }

    @Test("asynchronous test runs push progress until they finish")
    func pushedProgress() async throws {
        let notifications = StudioNotificationCenter()
        let locks = StudioDeviceLocks()
        let automation = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: RecordingToolExecutor(),
            notifications: notifications,
            deviceLocks: locks
        )
        let harness = TransportHarness(
            workspace: AutomationWorkspace(),
            automation: automation,
            notifications: notifications,
            deviceLocks: locks
        )
        let plan = StudioCompiledPlan(
            compiler: "test",
            compilerVersion: "1",
            toolOperations: [
                .init(id: "operation-1", tool: "tap_element", arguments: ["id": "login"]),
                .init(id: "operation-2", tool: "assert_visible", arguments: ["id": "home"])
            ]
        )
        let request = StudioTestRunRequest(test: authoredTest(plan: plan), deviceId: "emulator-5554", providerId: nil)
        let params = try #require(String(bytes: JSONEncoder().encode(request), encoding: .utf8))
        try harness.send(#"{"jsonrpc":"2.0","id":1,"method":"tests.start","params":"# + params + "}")

        var progress: [[String: Any]] = []
        while progress.last?["state"] as? String != "Passed" {
            let frame = try await harness.nextFrame()
            if frame["method"] as? String == "tests.progress", let params = frame["params"] as? [String: Any] {
                progress.append(params)
            }
        }

        let operations = progress.compactMap { $0["currentOperation"] as? Int }
        #expect(operations == operations.sorted())
        #expect(operations.last == 2)
        #expect(progress.first?["message"] as? String == "Preparing test…")
        await harness.finish()
    }

    @Test("handler failures keep the request id and use JSON-RPC error codes")
    func errorCodes() async throws {
        let service = StudioService(workspace: GatedWorkspace(gate: Gate(isOpen: true)))

        let missingParamRequest = #"{"jsonrpc":"2.0","id":4,"method":"devices.start","params":{}}"#
        let missingParam = try await object(service.handle(Data(missingParamRequest.utf8)))
        let invalidRequest = try await object(service.handle(Data(#"{"jsonrpc":"2.0","id":9}"#.utf8)))
        let parseError = try await object(service.handle(Data("{not json".utf8)))

        #expect(missingParam["id"] as? Int == 4)
        #expect((missingParam["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(invalidRequest["id"] as? Int == 9)
        #expect((invalidRequest["error"] as? [String: Any])?["code"] as? Int == -32600)
        #expect((parseError["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test("work on one device runs in arrival order while other devices proceed")
    func deviceOrdering() async throws {
        let locks = StudioDeviceLocks()
        let log = EventLog()
        let gate = Gate()

        let first = Task {
            try await locks.withDevice("sim-1") {
                await log.append("first-start")
                await gate.wait()
                await log.append("first-end")
            }
        }
        try await waitForEvent("first-start", in: log)
        let second = Task {
            try await locks.withDevice("sim-1") { await log.append("second") }
        }
        try await locks.withDevice("sim-2") { await log.append("other-device") }
        await gate.open()
        try await first.value
        try await second.value

        #expect(await log.events == ["first-start", "other-device", "first-end", "second"])
    }

    private func waitForEvent(_ event: String, in log: EventLog) async throws {
        for _ in 0 ..< 200 where await log.events.contains(event) == false {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Serves a `StudioService` over in-memory pipes, as `amoo studio serve` does over stdio.
private final class TransportHarness: Sendable {
    let service: StudioService
    private let input = Pipe()
    private let output = Pipe()
    private let serving: Task<Void, Never>

    init(
        workspace: any StudioDeviceWorkspace,
        automation: (any StudioAutomationServing)? = nil,
        notifications: StudioNotificationCenter = .init(),
        deviceLocks: StudioDeviceLocks = .init()
    ) {
        let service = StudioService(
            workspace: workspace,
            automation: automation ?? LiveStudioAutomationService(workspace: workspace, reportsURL: nil),
            notifications: notifications,
            deviceLocks: deviceLocks
        )
        self.service = service
        let reading = input.fileHandleForReading
        let writing = output.fileHandleForWriting
        serving = Task { await service.run(input: reading, output: writing) }
    }

    func send(_ json: String) throws {
        try ContentLengthFraming.writeMessage(Data(json.utf8), to: input.fileHandleForWriting)
    }

    func nextFrame() async throws -> [String: Any] {
        let handle = output.fileHandleForReading
        let data = try await Task.detached { try ContentLengthFraming.readMessage(from: handle) }.value
        return try object(#require(data))
    }

    func finish() async {
        try? input.fileHandleForWriting.close()
        await serving.value
    }
}

private actor Gate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor EventLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private struct GatedWorkspace: StudioDeviceWorkspace {
    let gate: Gate

    func listDevices() async -> [StudioDevice] {
        []
    }

    func startDevice(_: String) async -> StudioOperationResult {
        .init(message: "started", artifactPath: nil)
    }

    func createDevice(_: StudioCreateDeviceRequest) async -> StudioOperationResult {
        .init(message: "created", artifactPath: nil)
    }

    func buildInstallRun(_: StudioAppRequest) async -> StudioOperationResult {
        await gate.wait()
        return .init(message: "built", artifactPath: nil)
    }

    func reinstallRun(_: StudioAppRequest) async -> StudioOperationResult {
        .init(message: "installed", artifactPath: nil)
    }

    func resetData(_: StudioAppRequest) async -> StudioOperationResult {
        .init(message: "reset", artifactPath: nil)
    }
}
