import AmooCore
import Foundation

/// The Studio REPL's command surface.
///
/// Split out of `StudioAutomationService.swift` because it is a command dispatcher with its own
/// vocabulary, and folding it into the actor's main body pushed both past the size limits. Each
/// family gets a small handler returning `nil` when it does not recognize the command, mirroring
/// how `StudioService` routes JSON-RPC methods.
extension LiveStudioAutomationService {
    /// Commands that would destroy device or app state are refused outright: the REPL is an
    /// exploration surface, and an accidental `reset` there is unrecoverable.
    private static let destructivePattern = #"(^|\s)(reset|erase|delete|uninstall)(\s|$)"#

    private static let helpText = [
        "help",
        "devices list",
        "devices inspect <id>",
        "tests validate",
        "tests run",
        "sessions list",
        "reports list",
        "providers inspect <id>",
        "tap_element id=<id>|label=<label>",
        "set_text id=<id> value=<value>",
        "assert_visible id=<id>|label=<label>",
        "take_screenshot"
    ].joined(separator: "\n")

    public func execute(_ request: StudioReplRequest) async throws -> StudioReplResult {
        let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.range(of: Self.destructivePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            throw StudioAutomationError.destructiveCommand
        }

        if let result = try await exactCommandResult(command, request: request) {
            return result
        }
        if let result = try await prefixedCommandResult(command, request: request) {
            return result
        }
        if let result = try await toolOperationResult(command, request: request) {
            return result
        }
        throw StudioAutomationError.unsupportedCommand(command)
    }

    private func exactCommandResult(
        _ command: String,
        request: StudioReplRequest
    ) async throws -> StudioReplResult? {
        switch command.lowercased() {
        case "help":
            return .init(output: Self.helpText)
        case "devices list":
            let devices = await workspace.listDevices()
            let output = devices.isEmpty ? "No devices found." : devices
                .map { "[\($0.platform.rawValue)] \($0.name) (\($0.id)) — \($0.status.rawValue)" }
                .joined(separator: "\n")
            return .init(output: output)
        case "tests validate":
            try Self.validate(request.activeTest)
            return .init(
                output: "Test '\(request.activeTest.name)' is valid with \(request.activeTest.steps.count) step(s)."
            )
        case "tests run":
            return try await testRunResult(request)
        case "sessions list":
            return .init(output: storedReports.isEmpty ? "No sessions found." : storedReports
                .map { "Session report \($0.id) — \($0.testName)" }.joined(separator: "\n"))
        case "reports list":
            return .init(output: storedReports.isEmpty ? "No reports found." : storedReports
                .map { "[\($0.status.rawValue)] \($0.testName) — \($0.id)" }.joined(separator: "\n"))
        default:
            return nil
        }
    }

    private func testRunResult(_ request: StudioReplRequest) async throws -> StudioReplResult {
        guard let deviceID = request.selectedDeviceId else {
            throw StudioAutomationError.invalidTest("Choose a device before running the test.")
        }
        let result = try await run(.init(
            test: request.activeTest,
            deviceId: deviceID,
            providerId: request.selectedProviderId
        ))
        return .init(output: result.message)
    }

    private func prefixedCommandResult(
        _ command: String,
        request: StudioReplRequest
    ) async throws -> StudioReplResult? {
        let lowered = command.lowercased()

        if lowered.hasPrefix("devices inspect ") {
            let id = String(command.dropFirst("devices inspect ".count))
            guard let device = await workspace.listDevices().first(where: { $0.id == id }) else {
                throw StudioAutomationError.unsupportedCommand(command)
            }
            let details = [
                device.name,
                "ID: \(device.id)",
                "Platform: \(device.platform.rawValue)",
                "OS: \(device.osVersion)",
                "Status: \(device.status.rawValue)"
            ].joined(separator: "\n")
            return .init(output: details)
        }

        if lowered.hasPrefix("providers inspect "), let providerID = request.selectedProviderId {
            return .init(output: "Selected provider profile: \(providerID). Secrets remain environment-only.")
        }

        return nil
    }

    private func toolOperationResult(
        _ command: String,
        request: StudioReplRequest
    ) async throws -> StudioReplResult? {
        guard let operation = Self.parseToolOperation(command) else { return nil }
        guard let deviceID = request.selectedDeviceId else {
            throw StudioAutomationError.invalidTest("Choose a device before running mobile commands.")
        }
        guard let toolExecutor else {
            throw StudioAutomationError.invalidTest("Real device tool execution is unavailable in this Amoo build.")
        }
        let result = try await toolExecutor.execute(
            operation,
            deviceId: deviceID,
            platform: request.activeTest.platform.rawValue,
            appId: request.activeTest.requirements?.appId
        )
        return .init(output: result.output)
    }
}
