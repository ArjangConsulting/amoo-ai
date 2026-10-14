import Foundation
import StudioProtocol

/// Retain the effective plan and warnings with tool artifacts, outside test source directories.
func writeGenerationProvenance(plan: StudioAuthoredTest, sourcePath: String, generatedFile: URL) throws {
    struct Provenance: Encodable {
        let sourcePlan: String
        let effectivePlan: StudioAuthoredTest
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Provenance(sourcePlan: sourcePath, effectivePlan: plan))
    let directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent().appendingPathComponent("provenance")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(
        to: directory.appendingPathComponent(generatedFile.lastPathComponent + ".provenance.json"),
        options: .atomic
    )
}
