import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import MCPServer

struct TestFlow: Codable, Equatable {
    struct Step: Codable, Equatable {
        var name: String?
        var tool: String
        var arguments: [String: String]

        init(name: String? = nil, tool: String, arguments: [String: String] = [:]) {
            self.name = name
            self.tool = tool
            self.arguments = arguments
        }
    }

    var platform: String
    var port: Int?
    var deviceID: String?
    var steps: [Step]

    enum CodingKeys: String, CodingKey {
        case platform
        case port
        case deviceID = "device_id"
        case steps
    }
}

func renderFlowHelp() -> String {
    """
    Usage: amoo flow <path.amoo.json>

    Runs a checked-in sequence against one persistent driver connection. Argument values of
    the form ${ENV_NAME} are read from the environment, so credentials stay out of the file.
    Execution stops on the first failed action or assertion.
    """
}

func runFlowCommand(path: String) async -> CLIResult {
    var openCompanion: GRPCCompanionClient?
    do {
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        let flow = try JSONDecoder().decode(TestFlow.self, from: Data(contentsOf: fileURL))
        guard let platform = Platform(rawValue: flow.platform.lowercased()) else {
            return CLIResult(output: "Unknown flow platform '\(flow.platform)'.", exitCode: 64)
        }
        guard !flow.steps.isEmpty else {
            return CLIResult(output: "Flow has no steps: \(fileURL.path)", exitCode: 64)
        }

        let port = flow.port ?? (platform == .ios ? 22087 : 22088)
        let companion = try GRPCCompanionClient.makeLive(
            connection: CompanionConnection(host: "127.0.0.1", port: port)
        )
        openCompanion = companion
        let driver: any PlatformDriver = switch platform {
        case .ios:
            await makeIOSDriver(companion: companion, deviceID: flow.deviceID ?? "booted")
        case .android:
            AndroidDriver(
                companion: companion,
                inspectionMode: .productionDefault(),
                serial: normalizedAndroidDeviceID(flow.deviceID)
            )
        }
        let executor = DriverToolExecutor(driver: driver)
        var report: [String] = []

        for (index, step) in flow.steps.enumerated() {
            let arguments = try resolveEnvironment(in: step.arguments)
            let result = await executor.execute(toolName: step.tool, arguments: arguments)
            let label = step.name ?? step.tool
            if result.isError {
                report.append("✗ \(index + 1). \(label): \(result.content)")
                await companion.shutdown()
                openCompanion = nil
                return CLIResult(output: report.joined(separator: "\n"), exitCode: 1)
            }
            report.append("✓ \(index + 1). \(label): \(result.content)")
        }

        await companion.shutdown()
        openCompanion = nil
        return CLIResult(output: report.joined(separator: "\n"), exitCode: 0)
    } catch {
        if let openCompanion {
            await openCompanion.shutdown()
        }
        return CLIResult(output: "Flow failed: \(error)", exitCode: 1)
    }
}

private func normalizedAndroidDeviceID(_ deviceID: String?) -> String? {
    guard let deviceID, !deviceID.isEmpty, deviceID != "booted" else { return nil }
    return deviceID
}

private func resolveEnvironment(in arguments: [String: String]) throws -> [String: String] {
    try arguments.mapValues { value in
        guard value.hasPrefix("${"), value.hasSuffix("}") else { return value }
        let name = String(value.dropFirst(2).dropLast())
        guard let resolved = ProcessInfo.processInfo.environment[name] else {
            throw AmooError.commandFailed(
                command: "flow",
                output: "Missing environment variable: \(name)"
            )
        }
        return resolved
    }
}
