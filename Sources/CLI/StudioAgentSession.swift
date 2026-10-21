import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import MCP
import MCPServer
import ProcessRunner
import StudioProtocol
import TestSession

/// Drives Studio agent runs through the same session-backed executor `amoo mcp serve` uses, so a
/// run records a real session: `end_session` writes `plan.json` and `flow.json`, and the recording
/// feeds test generation exactly like an MCP client's session.
actor CLIStudioAgentSession: StudioAgentSessionDriving {
    private let iOSCompanionManager = CompanionManager()
    private let androidCompanionManager = AndroidCompanionManager()
    private var sessionManager: SessionManager?
    private var executor: DriverToolExecutor?

    func startSession(_ request: StudioAgentStartRequest) async throws -> String {
        let executor = try await executor(for: request)
        var arguments = [
            "app_id": request.appId,
            "platform": request.platform.lowercased(),
            "device_hint": request.deviceId,
            "test_name": request.activeTest.name
        ]
        if let buildPath = request.buildPath, !buildPath.isEmpty {
            arguments["build_path"] = buildPath
        }
        if let launchArguments = request.launchArguments, !launchArguments.isEmpty {
            arguments["launch_args"] = launchArguments.joined(separator: ",")
        }
        if !request.activeTest.description.isEmpty {
            arguments["test_description"] = request.activeTest.description
        }
        let result = await executor.execute(toolName: "start_session", arguments: arguments)
        guard !result.isError, let id = Self.string("session_id", in: result.structuredContent) else {
            throw StudioAgentError.invalidRequest("Could not start a session: \(result.content)")
        }
        return id
    }

    func execute(sessionId _: String, tool: String, arguments: [String: String]) async -> StudioAgentToolOutcome {
        guard let executor else { return .init(output: "No session is running.", isError: true) }
        let result = await executor.execute(toolName: tool, arguments: arguments)
        // The recorder's copy omits typed field text, which is all a timeline needs to show.
        return .init(
            output: result.recordedContent ?? result.content,
            isError: result.isError,
            structuredContent: result.structuredContent.flatMap(Self.jsonText)
        )
    }

    func observeScreen(sessionId: String) async -> StudioScreenshot? {
        guard let executor, let directory = await sessionManager?.sessionDirectory(for: sessionId) else { return nil }
        let screens = directory.appending(path: "studio-screens", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
        let output = screens.appending(path: "\(UUID().uuidString).png").path
        let result = await executor.observeScreenshot(arguments: [
            "session_id": sessionId,
            "output": output,
            "return_image": "false",
            "settle_timeout_ms": "1500"
        ])
        guard !result.isError else { return nil }
        let fields = result.structuredContent.flatMap(Self.jsonText).flatMap(StudioJSON.parse)
        return .init(
            path: fields?["saved_path"]?.stringValue ?? output,
            widthPixels: fields?["width_pixels"]?.intValue,
            heightPixels: fields?["height_pixels"]?.intValue,
            widthPoints: fields?["width_points"].flatMap(Self.double),
            heightPoints: fields?["height_points"].flatMap(Self.double),
            scale: fields?["scale"].flatMap(Self.double)
        )
    }

    func endSession(sessionId: String) async -> StudioAgentSessionEnd {
        guard let executor else { return .init(planPath: nil, flowPath: nil) }
        let result = await executor.execute(toolName: "end_session", arguments: ["session_id": sessionId])
        return .init(
            planPath: Self.string("plan_path", in: result.structuredContent),
            flowPath: Self.string("flow_path", in: result.structuredContent),
            message: result.isError ? result.content : nil
        )
    }

    func sessionDirectory(sessionId: String) async -> URL? {
        await sessionManager?.sessionDirectory(for: sessionId)
    }

    func shutdown() async {
        await sessionManager?.closeAll()
        await iOSCompanionManager.shutdown()
        await androidCompanionManager.shutdown()
    }

    /// Built on first use. Its default driver is never used for agent calls, which always carry a
    /// `session_id`, but the executor needs one, so it targets the run's device like MCP serve does.
    private func executor(for request: StudioAgentStartRequest) async throws -> DriverToolExecutor {
        if let executor {
            return executor
        }
        let platform = Platform(rawValue: request.platform.lowercased()) ?? .ios
        let manager = SessionManager(
            bootstrapper: DefaultSessionBootstrapper(
                iOSCompanionManager: iOSCompanionManager,
                androidCompanionManager: androidCompanionManager
            ),
            store: FileSessionStore()
        )
        let port = platform == .android ? await androidCompanionManager.companionPort(forSerial: request.deviceId)
            : IOSCompanionPort.forDevice(request.deviceId)
        let companion = try GRPCCompanionClient.makeLive(connection: .init(host: "127.0.0.1", port: port))
        let driver: any PlatformDriver = platform == .android
            ? AndroidDriver(companion: companion, inspectionMode: .productionDefault(), serial: request.deviceId)
            : await makeIOSDriver(companion: companion, deviceID: request.deviceId)
        let created = DriverToolExecutor(
            driver: driver,
            sessionManager: manager,
            foreignBuildDetector: ForeignBuildDetector(),
            webInspector: makeWebInspecting(processRunner: SystemProcessRunner()),
            defaultPlatform: platform
        )
        sessionManager = manager
        executor = created
        return created
    }

    private static func jsonText(_ value: Value) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    private static func string(_ key: String, in value: Value?) -> String? {
        guard case let .object(fields)? = value, case let .string(text)? = fields[key] else { return nil }
        return text
    }

    private static func double(_ value: StudioJSON) -> Double? {
        switch value {
        case let .double(number): number
        case let .int(number): Double(number)
        default: nil
        }
    }
}
