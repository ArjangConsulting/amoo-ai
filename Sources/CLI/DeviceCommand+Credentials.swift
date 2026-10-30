import AmooLogging
import Foundation
import MCPServer
import TestSession

private let logger = AmooLogger.forType(DeviceRuntime.self)

/// Each `amoo device` call is its own process, so the launch a credential is checked against is
/// carried on the runtime record between calls. Without a runtime, a credential is refused.
func executeCarryingCredentialLaunch(
    executor: DriverToolExecutor,
    options: DeviceCommandOptions,
    store: DeviceRuntimeStore = DeviceRuntimeStore(),
    run: () async -> ToolResult
) async -> ToolResult {
    let runtime = presentedRuntime(flag: options.runtimeID, store: store).flatMap { store.runtime(id: $0) }
    await seedCredentialLaunch(executor: executor, runtime: runtime)
    let result = await run()
    if options.tool == "device_launch_app", !result.isError {
        await persistCredentialLaunch(executor: executor, runtime: runtime, store: store)
    }
    return result
}

func seedCredentialLaunch(executor: DriverToolExecutor, runtime: DeviceRuntime?) async {
    guard let runtime, let appID = runtime.launchedAppID else { return }
    await executor.recordCredentialLaunch(appID: appID, environment: runtime.launchEnvironment ?? [:])
}

func persistCredentialLaunch(executor: DriverToolExecutor, runtime: DeviceRuntime?, store: DeviceRuntimeStore) async {
    guard var runtime, let launch = await executor.lastCredentialLaunch() else { return }
    runtime.launchedAppID = launch.appID
    runtime.launchEnvironment = maskedLaunchEnvironment(launch.environment)
    do {
        try store.replace(runtime)
    } catch {
        logger.error(
            "Could not record the launch on the runtime",
            error: error,
            context: "action=persistLaunch runtime=\(runtime.id) app=\(launch.appID)"
        )
    }
}

/// Values under sensitive keys never reach disk; such a key can only satisfy a `*` requirement.
func maskedLaunchEnvironment(_ environment: [String: String]) -> [String: String] {
    environment.reduce(into: [:]) { masked, entry in
        masked[entry.key] = ArtifactRedactor.isSensitiveKey(entry.key) ? "<redacted>" : entry.value
    }
}
