// swiftlint:disable multiline_arguments
import AmooCore

public extension AndroidDriver {
    func inspectionCapabilities() async -> InspectionCapabilities {
        InspectionCapabilities(platform: .android, provider: "android.\(inspectionMode.rawValue)")
    }

    func launchAppWithReceipt(
        appID: String, arguments: [String], environment: [String: String]
    ) async throws -> AppLaunchReceipt {
        try await launchApp(appID: appID, arguments: arguments, environment: environment)
        return AppLaunchReceipt(
            appID: appID, freshProcess: true,
            environmentDelivery: environment.isEmpty ? "not_requested" : "intent_extras",
            environmentKeys: Array(environment.keys),
            argumentsDelivery: arguments.isEmpty ? "not_requested" : "intent_extras",
            argumentCount: arguments.count
        )
    }
}

extension AndroidDriver: AppCompiling {
    /// `cmd package compile -m <mode> -f <appID>`; the forced recompile runs even when ART already
    /// considers the app compiled enough.
    public func compileApp(appID: String, mode: String) async throws -> String {
        let serial = activeSerial.map { ["-s", $0] } ?? []
        let result = try await adb.run(
            serial + ["shell", "cmd", "package", "compile", "-m", mode, "-f", appID], timeoutSeconds: 600
        )
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !output.lowercased().contains("failure") else {
            throw AmooError.commandFailed(command: "cmd package compile", output: output)
        }
        return output
    }
}

// swiftlint:enable multiline_arguments
