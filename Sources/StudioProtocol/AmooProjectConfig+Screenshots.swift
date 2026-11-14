import Foundation

/// The `screenshots` section of `amoo.config.json`: the project's capture defaults. Every capture is
/// saved to a file; these only choose its size and whether the image also goes back inline. Image
/// tokens grow with pixel area and an inline image is re-read on every later turn, so a smaller
/// `scale` and path-only delivery cut agent cost. They are defaults, never a block: a call's own
/// `scale` or `return_image` argument wins. `amoo init` asks for them; the MCP server and
/// `amoo device` apply them.
public struct ScreenshotPolicy: Codable, Equatable, Sendable {
    /// Image size relative to the default of one pixel per point (iOS) or dp (Android), in (0, 1].
    /// It sizes the saved file and any returned image alike.
    public var scale: Double
    /// Whether `take_screenshot` also returns the image inline when the call does not say.
    public var returnImage: Bool

    public static let standard = Self()

    enum CodingKeys: String, CodingKey {
        case scale
        case returnImage = "return_image"
    }

    public init(scale: Double = 1, returnImage: Bool = false) {
        self.scale = scale
        self.returnImage = returnImage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        returnImage = try container.decodeIfPresent(Bool.self, forKey: .returnImage) ?? false
    }

    /// Problems with the section, empty when it is valid.
    public func validationProblems() -> [String] {
        scale > 0 && scale <= 1 ? [] : ["screenshots.scale must be in (0, 1], got \(scale)"]
    }

    /// The effective policy for the project at or above `directory`: the layered `amoo.config.json`
    /// value, or `standard` when there is no config, no `screenshots` key, or the config is invalid
    /// (an invalid file is reported by `amoo config validate`, not by every capture).
    public static func resolve(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> Self {
        let files = AmooProjectConfig.discoverAll(from: directory)
        guard !files.isEmpty, let config = try? AmooProjectConfig.load(layers: files) else { return .standard }
        return config.screenshots ?? .standard
    }
}

public extension AmooProjectConfig {
    /// Sets the screenshot defaults in the config file at `file`, creating a minimal config when there
    /// is none and keeping every other key. The section is written even when it equals `standard`, so a
    /// platform repository can override an orchestrator's choice.
    static func writeScreenshotPolicy(_ policy: ScreenshotPolicy, to file: URL) throws {
        var config = FileManager.default.fileExists(atPath: file.path) ? try load(file) : Self()
        config.screenshots = policy
        try config.write(to: file)
    }
}
