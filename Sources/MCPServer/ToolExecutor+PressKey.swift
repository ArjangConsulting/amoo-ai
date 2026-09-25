import AmooCore

extension DriverToolExecutor {
    func executePressKey(arguments: [String: String], driver: any PlatformDriver) async throws -> ToolResult {
        let namedKeys = KeyboardKey.namedKeys.map(\.name).joined(separator: ", ")
        guard let name = arguments["key"], !name.isEmpty else {
            return .error("Missing required argument: key (\(namedKeys), or a single character)")
        }
        guard let key = KeyboardKey(name: name) else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "key must be one of \(namedKeys), or a single character"
            )
        }
        var modifiers: Set<KeyModifier> = []
        for raw in (arguments["modifiers"] ?? "").split(separator: ",") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard let modifier = KeyModifier(rawValue: trimmed) else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "modifiers must be a comma-separated list of: "
                        + KeyModifier.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            modifiers.insert(modifier)
        }
        try await driver.pressKey(key, modifiers: modifiers)
        let chord = (modifiers.sorted().map(\.rawValue) + [key.name]).joined(separator: "+")
        return .success("Pressed \(chord)")
    }
}
