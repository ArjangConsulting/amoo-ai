import AmooCore
import Foundation
import GradleKit
import ProcessRunner
import SwiftyShell

/// Resolves the port used by a running Android companion without allocating a new one.
/// Explicit ports win; ADB forwards identify physical devices and custom emulator ports.
func resolveAndroidCompanionPort(
    deviceID: String?,
    explicitPort: Int? = nil,
    processRunner: any ProcessRunner = SystemProcessRunner()
) async throws -> Int {
    if let explicitPort {
        return explicitPort
    }
    guard let deviceID, !deviceID.isEmpty, deviceID != "booted" else {
        return AndroidCompanionConfig.defaultPort
    }
    let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
    if let forwarded = try await forwardedAndroidCompanionPort(forSerial: deviceID, context: context) {
        return forwarded
    }
    if let fixed = AndroidCompanionConfig.emulatorPort(forSerial: deviceID) {
        return fixed
    }
    throw AmooError.commandFailed(
        command: "companion port resolution",
        output: "No companion TCP forward for \(deviceID); start a session or specify --port."
    )
}

/// Reads ADB's cross-process forward table. Amoo forwards the same TCP port on both ends.
func forwardedAndroidCompanionPort(forSerial serial: String, context: ShellContext) async throws -> Int? {
    let result = try await Adb(context: context).rawArguments(["forward", "--list"]).run().processResult
    guard result.exitCode == 0 else {
        throw AmooError.commandFailed(command: "adb forward --list", output: result.stderr)
    }
    let ports = Set(result.stdout.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, fields[0] == serial,
              fields[1] == fields[2], fields[1].hasPrefix("tcp:"),
              let port = Int(fields[1].dropFirst(4)),
              (AndroidCompanionConfig.defaultPort ... AndroidCompanionConfig.maxPort).contains(port)
        else { return nil }
        return port
    })
    guard ports.count <= 1 else {
        throw AmooError.commandFailed(
            command: "companion port resolution",
            output: "Multiple companion TCP forwards for \(serial); specify --port."
        )
    }
    return ports.first
}
