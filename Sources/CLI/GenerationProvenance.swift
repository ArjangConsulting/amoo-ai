import Foundation
import StudioProtocol

/// Retain the effective plan, its warnings and its origin beside exported code.
func writeGenerationProvenance(plan: StudioAuthoredTest, sourcePath: String, generatedFile: URL) throws {
    struct Provenance: Encodable {
        let sourcePlan: String
        let effectivePlan: StudioAuthoredTest
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Provenance(sourcePlan: sourcePath, effectivePlan: plan))
    try data.write(to: generatedFile.appendingPathExtension("provenance.json"), options: .atomic)
}
