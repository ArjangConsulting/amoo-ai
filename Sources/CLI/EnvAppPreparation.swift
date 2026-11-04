import AdbKit
import AmooCore
import Foundation
import IOSDriver
import MobileDevices
import ProcessRunner
import SwiftyShell
import XcrunKit

private struct EnvLaunchState: Decodable {
    let launch: AppLaunchReceipt?
    let verified: Bool?
    let semanticReadiness: String?
    let renderReadiness: String?

    enum CodingKeys: String, CodingKey {
        case launch, verified
        case semanticReadiness = "semantic_readiness"
        case renderReadiness = "render_readiness"
    }
}

private struct EnvLaunchResponse: Decodable {
    let structured: EnvLaunchState
}

func prepareEnvApp(_ options: EnvUpOptions, runtime: DeviceRuntime, app: inout EnvAppReport?) async throws {
    guard options.appPath != nil || options.appID != nil, let port = runtime.port else { return }

    func run(_ tool: String, _ arguments: [String: String]) async throws -> CLIResult {
        let result = await runDeviceCommand(options: DeviceCommandOptions(
            platform: options.platform,
            port: port,
            deviceID: runtime.deviceID,
            tool: tool,
            arguments: arguments,
            runtimeID: runtime.id,
            json: true
        ))
        guard result.exitCode == 0 else { throw EnvError.appFailed("\(tool) failed: \(result.output)") }
        return result
    }

    if let path = options.appPath {
        guard FileManager.default.fileExists(atPath: path) else { throw EnvError.appFailed("No app at \(path).") }
        _ = try await run("device_install_app", ["path": path])
        app?.installed = true
    }
    if let appID = options.appID {
        app?.installed = await isAppInstalled(platform: options.platform, deviceID: runtime.deviceID, appID: appID)
        guard app?.installed == true
        else { throw EnvError.appFailed("\(appID) is not installed on \(runtime.deviceID).") }
        if options.launch {
            let result = try await run("device_launch_app", ["app_id": appID])
            let state = try JSONDecoder().decode(EnvLaunchResponse.self, from: Data(result.output.utf8)).structured
            app?.launched = true
            app?.launch = state.launch
            app?.foregroundVerified = state.verified
            app?.semanticReadiness = state.semanticReadiness
            app?.renderReadiness = state.renderReadiness
        }
    } else {
        app?.installed = options.appPath != nil
    }
}

/// Read-only install check, independent of the companion.
private func isAppInstalled(platform: Platform, deviceID: String, appID: String) async -> Bool {
    let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner()))
    switch platform {
    case .android:
        return await (try? Adb(context: context).serial(deviceID).pmPath(package: appID).run()) != nil
    case .ios:
        return await (try? Simctl(context: context).getAppContainer(deviceID, bundleIdentifier: appID).run()) != nil
    case .macos:
        return SystemMacWorkspace().applicationURL(bundleID: appID) != nil
    }
}
