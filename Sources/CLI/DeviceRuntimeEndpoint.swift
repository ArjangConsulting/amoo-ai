import AdbKit
import Foundation
import ProcessRunner
import SwiftyShell

/// Confirms that the responding endpoint belongs to the device recorded by this runtime.
func runtimeEndpointReady(_ runtime: DeviceRuntime) async -> Bool {
    guard let port = runtime.port, await isCompanionReady(host: "127.0.0.1", port: port) else { return false }
    switch runtime.platform {
    case .ios:
        let owner = await companionSimulatorUDID(port: port, processRunner: SystemProcessRunner())
        return owner?.caseInsensitiveCompare(runtime.deviceID) == .orderedSame
    case .android:
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner()))
        guard let forwards = try? await Adb(context: context).listForwards().run() else { return false }
        return forwards.stdout.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 3 && fields[0] == runtime.deviceID && fields[1] == "tcp:\(port)"
        }
    }
}
