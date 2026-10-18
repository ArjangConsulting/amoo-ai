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
    var framework: String?
    var additionalLocations: [Self] = []

    func forPlatform(_ platform: Platform) -> Self? {
        ([self] + additionalLocations).first { $0.platform == platform || $0.platform == nil }
    }
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
        "Written by `amoo init`; re-run it to update. App builds are optional during device setup."
    ]
    for location in [saved] + saved.additionalLocations {
        if !saved.additionalLocations.isEmpty, let platform = location.platform {
            lines += ["", "### \(platform == .ios ? "iOS" : "Android")", ""]
        }
        if let platform = location.platform {
            lines.append("- Platform: `\(platform.rawValue)`")
        }
        if let framework = location.framework {
            lines.append("- Framework: `\(framework)`")
        }
        if let app = location.appPath {
            lines.append("- App artifact: `\(portableInitPath(app, relativeTo: base))`")
        }
        if let appID = location.appID {
            lines.append("- App ID: `\(appID)`")
        }
        if let directory = location.manifestDirectory {
            lines
                .append(
                    "- Manifests: `\(portableInitPath(directory, relativeTo: base))` (lease credentials; never commit)"
                )
        }
    }
    lines
        .append(
            "- Before recording or export, review `amoo.md` against existing tests and complete uncertain bindings."
        )
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

// Each managed field is handled independently in the location parser.
// swiftlint:disable:next cyclomatic_complexity
func parseInitLocations(from text: String, relativeTo base: String) -> InitSavedLocations? {
    guard let start = text.range(of: blockStart),
          let end = text.range(of: blockEnd, range: start.upperBound ..< text.endIndex)
    else { return nil }
    var saved = InitSavedLocations()
    var locations: [InitSavedLocations] = []
    func resolved(_ raw: String) -> String {
        absoluteInitPath(raw, workingDirectory: base)
    }
    for line in text[start.upperBound ..< end.lowerBound].split(separator: "\n") {
        let parts = line.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { continue }
        let value = String(parts[1])
        switch true {
        case line.hasPrefix("- Platform:"):
            if saved.platform != nil {
                locations.append(saved)
                saved = InitSavedLocations()
            }
            saved.platform = Platform(rawValue: value)
        case line.hasPrefix("- Framework:"): saved.framework = value
        case line.hasPrefix("- App artifact:"): saved.appPath = resolved(value)
        case line.hasPrefix("- App ID:"): saved.appID = value
        case line.hasPrefix("- Manifests:"): saved.manifestDirectory = resolved(value)
        default: continue
        }
    }
    if !locations.isEmpty {
        locations.append(saved)
        saved = locations.removeFirst()
        saved.additionalLocations = locations
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
    var merged = saved
    let incoming = [saved] + saved.additionalLocations
    if let previous = parseInitLocations(from: existing, relativeTo: base) {
        merged.additionalLocations += ([previous] + previous.additionalLocations).filter { location in
            !incoming.contains { $0.platform == location.platform }
        }.map { location in
            var entry = location
            entry.additionalLocations = []
            return entry
        }
    }
    let updated = upsertInitBlock(into: existing, block: renderInitLocationsBlock(merged, relativeTo: base))
    try updated.write(toFile: agentsFile, atomically: true, encoding: .utf8)
}
