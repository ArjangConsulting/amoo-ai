import StudioProtocol

/// The repository's relaunch call for a recorded `relaunch_application`.
enum TestCodeGeneratorRelaunch {
    /// `relaunchHelper`, once every environment key the recorded relaunch left out is one the context
    /// declares a state reset. A relaunch that dropped anything else changed the app's configuration,
    /// which a helper that only preserves state would not reproduce.
    static func call(for operation: StudioToolOperation, context: StudioTestContext?) throws -> String {
        guard let call = context?.relaunchHelper else {
            throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "relaunchHelper")
        }
        let dropped = (operation.arguments["without_environment"] ?? "")
            .split(separator: ",").map(String.init)
        let resets = Set(context?.relaunchResetEnvironmentKeys ?? [])
        if let unexplained = dropped.first(where: { !resets.contains($0) }) {
            throw TestCodeGeneratorError.invalidArgument(
                tool: operation.tool,
                argument: "without_environment",
                value: "\(unexplained) (list it in the context's relaunchResetEnvironmentKeys if it only resets state)"
            )
        }
        return call
    }
}
