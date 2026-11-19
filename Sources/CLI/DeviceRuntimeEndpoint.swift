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
        let forwarded = forwards.stdout.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 3 && fields[0] == runtime.deviceID && fields[1] == "tcp:\(port)"
        }
        guard forwarded else { return false }
        // The gRPC server lives in the companion's app process, which can outlive the
        // `am instrument` session that owns UiAutomation. It then still answers capabilities while
        // every UI call fails, and `env up --runtime-id` reported such a runtime as running.
        let processes = try? await Adb(context: context).serial(runtime.deviceID).shell("ps -A -o ARGS").run()
        return processes.map { androidInstrumentationRunning(psOutput: $0.stdout, port: port) } ?? true

    case .macos:
        // There is one Mac, so a companion answering on the runtime's port is the one it recorded.
        return true
    }
}

/// Whether `ps -A -o ARGS` on the device lists the companion's `am instrument` for `port`.
func androidInstrumentationRunning(psOutput: String, port: Int) -> Bool {
    psOutput.split(whereSeparator: \.isNewline).contains { line in
        line.contains(" instrument ") && line.contains("com.amoo.companion.CompanionRunner")
            && line.contains("-e port \(port) ")
    }
}
