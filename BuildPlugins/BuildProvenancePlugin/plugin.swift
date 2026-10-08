import Foundation
import PackagePlugin

@main
struct BuildProvenancePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target _: Target) throws -> [Command] {
        [.prebuildCommand(
            displayName: "Stamp amoo source provenance",
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                context.package.directoryURL.appending(path: "scripts/build-provenance.sh").path,
                context.package.directoryURL.path,
                context.pluginWorkDirectoryURL.path
            ],
            outputFilesDirectory: context.pluginWorkDirectoryURL
        )]
    }
}
