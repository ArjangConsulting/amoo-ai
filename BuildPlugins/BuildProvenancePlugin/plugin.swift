import Foundation
import PackagePlugin

@main
struct BuildProvenancePlugin: BuildToolPlugin {
    /// Everything `scripts/source-fingerprint.sh` hashes, plus the git files that move when HEAD does.
    /// A prebuild command only re-runs when SwiftPM re-plans, so an edited or newly committed checkout kept
    /// the previous commit and fingerprint. Declaring these as inputs re-stamps the build whenever any changes.
    private static let sourceRoots = ["Sources", "Protos", "BuildPlugins"]
    private static let sourceFiles = ["Package.swift", "Package.resolved", "scripts/build-provenance.sh"]
    private static let gitFiles = [".git/HEAD", ".git/index", ".git/logs/HEAD"]

    func createBuildCommands(context: PluginContext, target _: Target) throws -> [Command] {
        let root = context.package.directoryURL
        let output = context.pluginWorkDirectoryURL.appending(path: "CompiledBuildProvenance.swift")
        return [.buildCommand(
            displayName: "Stamp amoo source provenance",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                root.appending(path: "scripts/build-provenance.sh").path,
                root.path,
                context.pluginWorkDirectoryURL.path
            ],
            inputFiles: Self.inputs(root: root),
            outputFiles: [output]
        )]
    }

    private static func inputs(root: URL) -> [URL] {
        let manager = FileManager.default
        var found = (sourceFiles + gitFiles)
            .map { root.appending(path: $0) }
            .filter { manager.fileExists(atPath: $0.path) }
        for directory in sourceRoots {
            let base = root.appending(path: directory)
            guard let walker = manager.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                found.append(url)
            }
        }
        return found
    }
}
