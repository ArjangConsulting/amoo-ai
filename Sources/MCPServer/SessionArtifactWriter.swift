import Foundation

/// Writes the replay/codegen artifacts for a compiled session next to its
/// `report.json`, so every driven flow leaves a reusable plan on disk without
/// an agent having to remember to ask for one.
///
/// - `plan.json`  — the `StudioAuthoredTest` (with its embedded `compiledPlan`
///   and `warnings`), consumable directly by `amoo generate test --plan`.
/// - `flow.json`  — the `CompiledSessionFlow`, runnable directly by `amoo flow`.
enum SessionArtifactWriter {
    struct Paths: Sendable {
        let plan: String
        let flow: String
    }

    /// `StudioAuthoredTest` and `CompiledSessionFlow` are plain string/int trees
    /// (no `Date` fields), so a default decoder on the `amoo` side reads these
    /// back — keep the encoder free of date/key strategies to match.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static func write(_ result: CompileSessionToPlanResult, to directory: URL) throws -> Paths {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )

        let planURL = directory.appending(path: "plan.json")
        try encoder.encode(result.studioTest).write(to: planURL, options: .atomic)

        let flowURL = directory.appending(path: "flow.json")
        try encoder.encode(result.testFlow).write(to: flowURL, options: .atomic)

        for url in [planURL, flowURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return Paths(plan: planURL.path, flow: flowURL.path)
    }
}
