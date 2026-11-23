import AmooCore
import AmooLogging
import Foundation
import ProcessRunner

private let logger = AmooLogger.forType(AndroidDriver.self)

/// Copying files out of an app's storage: `adb pull` for its external directory, which any build
/// allows, and `run-as` for its internal data, which only a debuggable build allows.
extension AndroidDriver {
    /// Long enough for a large file over a slow USB link; a missing file fails much sooner.
    private static let transferTimeoutSeconds: TimeInterval = 120

    public func pullAppFile(_ request: AppFileRequest) async throws -> PulledAppFile {
        logger.debug("Pulling app file: container=\(request.container.rawValue)")
        switch request.container {
        case .external:
            return try await pullExternalFile(request)
        case .data:
            return try await pullInternalFile(request)
        }
    }

    private func pullExternalFile(_ request: AppFileRequest) async throws -> PulledAppFile {
        let devicePath = "/sdcard/Android/data/\(request.appID)/\(request.path)"
        let probe = try await adbOutcome(["shell", "test", "-f", Self.shellQuoted(devicePath)])
        guard probe.exitCode == 0 else { throw AppFileError.notFound(devicePath: devicePath) }
        try request.prepareDestination()
        let pull = try await adbOutcome(["pull", devicePath, request.destination.path])
        guard pull.exitCode == 0 else {
            throw AppFileError.unreadable(devicePath: devicePath, reason: "adb pull failed: \(pull.output)")
        }
        return try request.pulled(devicePath: devicePath)
    }

    /// `run-as` starts in the app's data directory, so the request's relative path is used as is.
    /// The file comes back as base64, because `adb` output is read as text.
    private func pullInternalFile(_ request: AppFileRequest) async throws -> PulledAppFile {
        let devicePath = "/data/data/\(request.appID)/\(request.path)"
        let quoted = Self.shellQuoted(request.path)
        let probe = try await adbOutcome(["shell", "run-as", request.appID, "test", "-f", quoted])
        if let reason = Self.runAsRefusal(probe.output, appID: request.appID) {
            throw AppFileError.unreadable(devicePath: devicePath, reason: reason)
        }
        guard probe.exitCode == 0 else { throw AppFileError.notFound(devicePath: devicePath) }
        let read = try await adbOutcome(["shell", "run-as", request.appID, "base64", quoted])
        guard read.exitCode == 0,
              let data = Data(base64Encoded: read.stdout, options: .ignoreUnknownCharacters)
        else {
            throw AppFileError.unreadable(devicePath: devicePath, reason: "run-as could not read it: \(read.output)")
        }
        return try request.write(data, devicePath: devicePath)
    }

    /// Why `run-as` refused, or `nil` when it ran: it refuses a release build, a system package and an
    /// unknown package.
    static func runAsRefusal(_ output: String, appID: String) -> String? {
        if output.contains("not an application") {
            return "\(appID) is a system package, whose internal storage run-as cannot read."
        }
        if output.contains("not debuggable") {
            return "\(appID) is not a debuggable build, so its internal storage is not readable."
                + " Use a debug build, or have the app write the file to its external files directory"
                + " and pull it with container 'external'."
        }
        if output.contains("unknown package") {
            return "\(appID) is not installed."
        }
        return nil
    }

    /// One argument for the device's `sh`, which `adb shell` hands its arguments to joined by spaces.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command's exit code and output, whether `adb` reports a failure by exit code or by throwing.
    private func adbOutcome(_ arguments: [String]) async throws -> ProcessResult {
        do {
            return try await adb.run(adbArgs() + arguments, timeoutSeconds: Self.transferTimeoutSeconds)
        } catch let ProcessRunnerError.nonZeroExit(_, exitCode, stderr) {
            return ProcessResult(exitCode: exitCode, stdout: "", stderr: stderr)
        }
    }
}

private extension ProcessResult {
    var output: String {
        stderr + stdout
    }
}
