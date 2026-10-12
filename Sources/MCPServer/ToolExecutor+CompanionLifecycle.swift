import AmooCore
import AuditEngine
import Foundation
import MCP
import StudioProtocol
import TestSession

extension DriverToolExecutor {
    func executeCompanionStatus(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Companion management requires `amoo mcp serve`.")
        }
        if let sessionID = arguments["session_id"] {
            return await sessionHealth(sessionID: sessionID, manager: manager)
        }
        let platformRaw = arguments["platform"] ?? defaultPlatform?.rawValue ?? "ios"
        guard let platform = Platform(rawValue: platformRaw.lowercased()) else {
            return .error("Unknown platform '\(platformRaw)'. Expected 'ios' or 'android'.")
        }
        do {
            let status = try await manager.companionStatus(
                platform: platform,
                deviceHint: arguments["device_hint"]
            )
            return .success(status, structuredContent: .object(["status": .string(status)]))
        } catch {
            return .error("companion_status failed: \(error)")
        }
    }

    /// One probe of a live session's connection: does the device answer, how fast, and what is in front.
    private func sessionHealth(sessionID: String, manager: SessionManager) async -> ToolResult {
        guard let session = await manager.session(sessionID) else {
            return .error("Session not found: \(sessionID)")
        }
        guard await session.isActive else {
            return .success(
                "session closed",
                structuredContent: .object(["status": .string("closed"), "session_id": .string(sessionID)])
            )
        }
        let started = ContinuousClock.now
        do {
            let app = try await session.driver.currentApp()
            let elapsed = started.duration(to: .now)
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components
                .attoseconds / 1_000_000_000_000_000)
            let status = "ready (rpc \(milliseconds)ms, foreground \(app.bundleID))"
            return await .success(status, structuredContent: .object([
                "status": .string("ready"),
                "session_id": .string(sessionID),
                "device_id": .string(session.deviceID),
                "rpc_ok": .bool(true),
                "rpc_ms": .int(milliseconds),
                "foreground_app": .string(app.bundleID),
                "target_app": .string(app.targetBundleID),
                "recording_health": .string(manager.recordingHealth(for: sessionID))
            ]))
        } catch {
            let status = "unresponsive: \(error). Try end_session force=true, then reset_companion, then start_session."
            return .success(status, structuredContent: .object([
                "status": .string("unresponsive"),
                "session_id": .string(sessionID),
                "device_id": .string(session.deviceID),
                "rpc_ok": .bool(false)
            ]))
        }
    }

    func executeResetCompanion(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Companion management requires `amoo mcp serve`.")
        }
        let platformRaw = arguments["platform"] ?? defaultPlatform?.rawValue ?? "ios"
        guard let platform = Platform(rawValue: platformRaw.lowercased()) else {
            return .error("Unknown platform '\(platformRaw)'. Expected 'ios' or 'android'.")
        }
        do {
            let status = try await manager.resetCompanion(platform: platform, deviceHint: arguments["device_hint"])
            return .success(status, structuredContent: .object(["status": .string(status)]))
        } catch {
            return .error("reset_companion failed: \(error)")
        }
    }
}
