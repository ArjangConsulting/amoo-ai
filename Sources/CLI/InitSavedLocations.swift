import AmooCore
import Foundation

/// Where `amoo init` last found things, recorded in the repo's `AGENTS.md` so the next run (and any
/// agent reading the file) starts from the same places. Only locations are stored: never device ids
/// or lease ids, which are per-machine and per-run.
struct InitSavedLocations: Equatable {
    var platform: Platform?
    var appPath: String?
    var appID: String?
    var manifestDirectory: String?
}

private let blockStart = "<!-- amoo:init:start -->"
private let blockEnd = "<!-- amoo:init:end -->"

/// Repo-relative when the path is inside `base`, `~`-relative inside the home directory, else absolute.
func portableInitPath(_ path: String, relativeTo base: String, home: String = NSHomeDirectory()) -> String {
    if path.hasPrefix(base + "/") {
        return String(path.dropFirst(base.count + 1))
    }
    if path.hasPrefix(home + "/") {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

func renderInitLocationsBlock(_ saved: InitSavedLocations, relativeTo base: String) -> String {
    var lines = [
        blockStart,
        "## amoo init",
        "",
        "Written by `amoo init`; re-run it to update. Build the app externally: init never rebuilds it."
    ]
    if let platform = saved.platform {
        lines.append("- Platform: `\(platform.rawValue)`")
    }
    if let app = saved.appPath {
        lines.append("- App artifact: `\(portableInitPath(app, relativeTo: base))`")
    }
    if let appID = saved.appID {
        lines.append("- App ID: `\(appID)`")
    }
    if let directory = saved.manifestDirectory {
        lines
            .append("- Manifests: `\(portableInitPath(directory, relativeTo: base))` (lease credentials; never commit)")
    }
    lines.append("- Prepare devices: `amoo init` (guided) or `amoo init --help`")
    lines.append(blockEnd)
    return lines.joined(separator: "\n")
}

/// Replaces the managed block, or appends one; text outside the markers is never touched.
func upsertInitBlock(into text: String, block: String) -> String {
    if let start = text.range(of: blockStart), let end = text.range(
        of: blockEnd,
        range: start.upperBound ..< text.endIndex
    ) {
        return text.replacingCharacters(in: start.lowerBound ..< end.upperBound, with: block)
    }
    let separator = text.isEmpty ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
    return text + separator + block + "\n"
}

func parseInitLocations(from text: String, relativeTo base: String) -> InitSavedLocations? {
    guard let start = text.range(of: blockStart),
          let end = text.range(of: blockEnd, range: start.upperBound ..< text.endIndex)
    else { return nil }
    var saved = InitSavedLocations()
    func resolved(_ raw: String) -> String {
        absoluteInitPath(raw, workingDirectory: base)
    }
    for line in text[start.upperBound ..< end.lowerBound].split(separator: "\n") {
        let parts = line.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { continue }
        let value = String(parts[1])
        switch true {
        case line.hasPrefix("- Platform:"): saved.platform = Platform(rawValue: value)
        case line.hasPrefix("- App artifact:"): saved.appPath = resolved(value)
        case line.hasPrefix("- App ID:"): saved.appID = value
        case line.hasPrefix("- Manifests:"): saved.manifestDirectory = resolved(value)
        default: continue
        }
    }
    return saved
}

func readInitLocations(agentsFile: String) -> InitSavedLocations? {
    guard let text = try? String(contentsOfFile: agentsFile, encoding: .utf8) else { return nil }
    return parseInitLocations(from: text, relativeTo: URL(fileURLWithPath: agentsFile).deletingLastPathComponent().path)
}

func saveInitLocations(_ saved: InitSavedLocations, agentsFile: String) throws {
    let base = URL(fileURLWithPath: agentsFile).deletingLastPathComponent().path
    let existing = (try? String(contentsOfFile: agentsFile, encoding: .utf8)) ?? ""
    let updated = upsertInitBlock(into: existing, block: renderInitLocationsBlock(saved, relativeTo: base))
    try updated.write(toFile: agentsFile, atomically: true, encoding: .utf8)
}
