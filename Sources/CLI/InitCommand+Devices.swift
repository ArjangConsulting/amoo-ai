import Foundation

/// The devices `init device` can reach, with the manifests searched, so a missing or wrong `--device`
/// names what to pass instead of repeating a usage block.
func initDeviceListing(_ manifests: [InitManifest], paths: [String]) -> String {
    let devices = manifests.flatMap { manifest in
        manifest.results.filter(\.ok).compactMap { entry in
            entry.device.map { device in
                (["  \(device.id)", entry.platform] + [device.name].compactMap(\.self)).joined(separator: "  ")
            }
        }
    }
    let searched = "Searched: " + paths.joined(separator: ", ")
    guard !devices.isEmpty else {
        return "No devices are initialized; run `amoo init` first.\n" + searched
    }
    return "Initialized devices:\n" + devices.joined(separator: "\n") + "\n" + searched
}

/// `amoo init device --device <id> <tool> ...`: routes the call through the manifest that owns the device.
func runInitDevice(args: [String], manifests: [InitManifest], paths: [String]) async throws -> CLIResult {
    var args = args
    guard let index = args.firstIndex(of: "--device"), args.indices.contains(index + 1) else {
        throw EnvCommandParseError.usage(
            "--device <id> is required.\n" + initDeviceListing(manifests, paths: paths)
        )
    }
    let device = args[index + 1]
    args.removeSubrange(index ... index + 1)
    guard let owner = manifests.first(where: { $0.results.contains { $0.ok && $0.device?.id == device } }) else {
        throw EnvCommandParseError.usage(
            "No successful init entry for device \(device).\n" + initDeviceListing(manifests, paths: paths)
        )
    }
    return try await CLIApp().run(args: ["device"] + initDeviceArguments(owner, device: device, args: args))
}
