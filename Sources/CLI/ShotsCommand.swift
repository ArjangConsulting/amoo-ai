import Foundation

// MARK: - `amoo shots`: contact sheets and baseline diffs for screenshot folders

func renderShotsHelp() -> String {
    """
    Usage: amoo shots montage <dir> [--out <sheet.png>] [--columns <n>] [--cell-width <px>]
           amoo shots diff <baseline-dir> <current-dir> [--out <diff-dir>] [--threshold <ratio>]
                           [--tolerance <0-255>] [--allow-new]

    Works on the PNGs `amoo flow --output-dir` and take_screenshot leave behind.

    montage   Lays every PNG in <dir> (by file name) out in one captioned grid, so a whole walk
              through the app can be reviewed — or handed to a model — as a single image.
              Defaults: --out <dir>/contact-sheet.png, --columns 4, --cell-width 320.

    diff      Compares screenshots of the same name in two folders. A file fails when it is missing
              from <current-dir>, differs in size, or more than --threshold (default 0.001, i.e.
              0.1%) of its pixels moved by more than --tolerance (default 8) in any colour channel.
              Files only in <current-dir> are reported as new, and fail unless --allow-new is given.
              --out writes a red-highlighted diff image for each failing file. Exit 0 = all match,
              1 = something changed.
    """
}

struct ShotsMontageOptions: Equatable {
    var directory: String
    var output: String?
    var columns = 4
    var cellWidth = 320
}

struct ShotsDiffOptions: Equatable {
    var baseline: String
    var current: String
    var output: String?
    var threshold = 0.001
    var tolerance = 8
    var allowNew = false
}

enum ShotsInvocation: Equatable {
    case montage(ShotsMontageOptions)
    case diff(ShotsDiffOptions)
}

enum ShotsParseError: Error, Equatable, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case let .usage(message): message
        }
    }
}

func parseShotsArguments(_ args: [String]) throws -> ShotsInvocation {
    guard let action = args.first else { throw ShotsParseError.usage(renderShotsHelp()) }
    var positionals: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var index = 1
    while index < args.count {
        let token = args[index]
        if token == "--allow-new" {
            flags.insert(token)
        } else if token.hasPrefix("--") {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw ShotsParseError.usage("\(token) needs a value.")
            }
            values[token] = args[index + 1]
            index += 1
        } else {
            positionals.append(token)
        }
        index += 1
    }
    switch action {
    case "montage":
        return try .montage(parseMontage(positionals: positionals, values: values))
    case "diff":
        return try .diff(parseDiff(positionals: positionals, values: values, flags: flags))
    default:
        throw ShotsParseError.usage("Unknown shots action '\(action)'.\n\n" + renderShotsHelp())
    }
}

private func parseMontage(positionals: [String], values: [String: String]) throws -> ShotsMontageOptions {
    guard positionals.count == 1 else { throw ShotsParseError.usage("montage takes one directory.") }
    var options = ShotsMontageOptions(directory: positionals[0], output: values["--out"])
    if let raw = values["--columns"] {
        guard let columns = Int(raw), columns > 0 else {
            throw ShotsParseError.usage("--columns expects a positive number.")
        }
        options.columns = columns
    }
    if let raw = values["--cell-width"] {
        guard let width = Int(raw), width >= 40 else {
            throw ShotsParseError.usage("--cell-width expects at least 40.")
        }
        options.cellWidth = width
    }
    return options
}

private func parseDiff(positionals: [String], values: [String: String], flags: Set<String>) throws -> ShotsDiffOptions {
    guard positionals.count == 2 else {
        throw ShotsParseError.usage("diff takes a baseline and a current directory.")
    }
    var options = ShotsDiffOptions(baseline: positionals[0], current: positionals[1], output: values["--out"])
    if let raw = values["--threshold"] {
        guard let threshold = Double(raw), (0 ... 1).contains(threshold) else {
            throw ShotsParseError.usage("--threshold expects a ratio between 0 and 1.")
        }
        options.threshold = threshold
    }
    if let raw = values["--tolerance"] {
        guard let tolerance = Int(raw), (0 ... 255).contains(tolerance) else {
            throw ShotsParseError.usage("--tolerance expects 0-255.")
        }
        options.tolerance = tolerance
    }
    options.allowNew = flags.contains("--allow-new")
    return options
}

func runShotsCommand(args: [String]) -> CLIResult {
    if args.isEmpty || args.first == "--help" || args.first == "-h" || args.first == "help" {
        return CLIResult(output: renderShotsHelp(), exitCode: args.isEmpty ? 64 : 0)
    }
    do {
        switch try parseShotsArguments(args) {
        case let .montage(options): return runShotsMontage(options)
        case let .diff(options): return runShotsDiff(options)
        }
    } catch {
        return CLIResult(output: "\(error)", exitCode: 64)
    }
}

/// The PNG files directly inside `directory`, by name.
func screenshotFiles(in directory: String) -> [URL] {
    let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
    let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    return contents.filter { $0.pathExtension.lowercased() == "png" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreText)
private func runShotsMontage(_ options: ShotsMontageOptions) -> CLIResult {
    let files = screenshotFiles(in: options.directory)
        .filter { $0.lastPathComponent != "contact-sheet.png" }
    guard !files.isEmpty else {
        return CLIResult(output: "No PNG screenshots in \(options.directory).", exitCode: 1)
    }
    let entries = files.compactMap { file in
        ScreenshotBitmap.load(from: file).map {
            ContactSheetEntry(caption: file.deletingPathExtension().lastPathComponent, bitmap: $0)
        }
    }
    guard !entries.isEmpty, let data = ScreenshotContactSheet.render(
        entries, columns: options.columns, cellWidth: options.cellWidth
    ) else {
        return CLIResult(output: "Could not render a contact sheet from \(options.directory).", exitCode: 1)
    }
    let output = options.output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? URL(fileURLWithPath: (options.directory as NSString).expandingTildeInPath)
        .appending(path: "contact-sheet.png")
    do {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: output)
    } catch {
        return CLIResult(output: "Could not write \(output.path): \(error)", exitCode: 1)
    }
    let skipped = files.count - entries.count
    let note = skipped > 0 ? " (\(skipped) unreadable file(s) skipped)" : ""
    return CLIResult(output: "Wrote \(output.path): \(entries.count) screenshot(s)\(note).", exitCode: 0)
}

private func runShotsDiff(_ options: ShotsDiffOptions) -> CLIResult {
    let baselineFiles = screenshotFiles(in: options.baseline)
    let currentByName = Dictionary(
        uniqueKeysWithValues: screenshotFiles(in: options.current).map { ($0.lastPathComponent, $0) }
    )
    guard !baselineFiles.isEmpty else {
        return CLIResult(output: "No PNG screenshots in baseline \(options.baseline).", exitCode: 1)
    }
    var lines: [String] = []
    var failures = 0
    for file in baselineFiles {
        let name = file.lastPathComponent
        guard let currentFile = currentByName[name] else {
            lines.append("MISSING  \(name)")
            failures += 1
            continue
        }
        guard let baseline = ScreenshotBitmap.load(from: file),
              let current = ScreenshotBitmap.load(from: currentFile) else {
            lines.append("UNREADABLE  \(name)")
            failures += 1
            continue
        }
        guard let difference = ScreenshotComparison.difference(baseline, current, tolerance: options.tolerance) else {
            lines.append("SIZE     \(name)  \(baseline.width)x\(baseline.height) -> \(current.width)x\(current.height)")
            failures += 1
            continue
        }
        let percent = String(format: "%.3f%%", difference.ratio * 100)
        if difference.ratio > options.threshold {
            lines.append("CHANGED  \(name)  \(percent) of pixels")
            failures += 1
            writeOverlay(baseline, current, name: name, options: options)
        } else {
            lines.append("same     \(name)  \(percent)")
        }
    }
    let baselineNames = Set(baselineFiles.map(\.lastPathComponent))
    for name in currentByName.keys.sorted() where !baselineNames.contains(name) {
        lines.append("NEW      \(name)")
        if !options.allowNew {
            failures += 1
        }
    }
    lines.append("")
    lines
        .append(failures == 0 ? "All screenshots match the baseline." :
            "\(failures) screenshot(s) differ from the baseline.")
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: failures == 0 ? 0 : 1)
}

private func writeOverlay(
    _ baseline: ScreenshotBitmap,
    _ current: ScreenshotBitmap,
    name: String,
    options: ShotsDiffOptions
) {
    guard let output = options.output,
          let overlay = ScreenshotComparison.overlay(baseline, current, tolerance: options.tolerance),
          let data = overlay.pngData()
    else { return }
    let directory = URL(fileURLWithPath: (output as NSString).expandingTildeInPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appending(path: "diff-\(name)"))
}
#else
private func runShotsMontage(_: ShotsMontageOptions) -> CLIResult {
    CLIResult(output: "amoo shots needs CoreGraphics, which this platform does not have.", exitCode: 1)
}

private func runShotsDiff(_: ShotsDiffOptions) -> CLIResult {
    CLIResult(output: "amoo shots needs CoreGraphics, which this platform does not have.", exitCode: 1)
}
#endif
