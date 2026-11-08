// swiftlint:disable multiline_parameters
import AmooTelemetry
import Foundation

/// Reads Claude Code transcripts (`~/.claude/projects/<project>/*.jsonl`, including
/// `*/subagents/*.jsonl`) for real token usage. Only usage numbers, tool names, ids and result
/// sizes are read into the report; message text and images never leave this reader.
///
/// A tool result's cost is measured, not estimated: the context of the assistant turn after the
/// result minus the context and output of the turn that issued the call is what the results in
/// between added. That growth is shared among the results in the gap by their size, and the
/// "carried" cost multiplies it by every later turn that re-reads it (mostly as cache reads).
enum UsageTranscriptReader {
    struct ToolUse {
        var id: String
        /// The amoo tool this client call reached, or nil for any other tool.
        var amooTool: String?
    }

    struct Turn {
        var messageID: String
        var timestamp: Date?
        var input = 0
        var cacheRead = 0
        var cacheCreation = 0
        var output = 0
        var toolUses: [ToolUse] = []

        /// Everything the model read for this turn.
        var context: Int {
            input + cacheRead + cacheCreation
        }
    }

    struct ResultSize {
        var characters = 0
        var images: [(width: Int, height: Int)] = []

        var imageTokens: Int {
            images.map { UsageStatistics.imageTokens(width: $0.width, height: $0.height) }.reduce(0, +)
        }

        var estimatedTokens: Int {
            characters / 4 + imageTokens
        }
    }

    /// Default transcript folder for the current working directory, as Claude Code names it.
    static func defaultDirectory(cwd: String = FileManager.default.currentDirectoryPath) -> URL {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects/\(slug)")
    }

    static func transcriptFiles(in directory: URL) -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            url.pathExtension == "jsonl"
        }
    }

    /// The amoo tool behind a client tool call: `mcp__<server containing amoo>__<tool>`, or `cli <command>`
    /// for an `amoo …` shell command.
    static func amooTool(name: String, input: [String: Any]?) -> String? {
        let parts = name.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp", parts[1].lowercased().contains("amoo") {
            return parts[2...].joined(separator: "__")
        }
        guard name == "Bash", let command = input?["command"] as? String else { return nil }
        return cliCommand(command).map { "cli " + $0 }
    }

    /// Drops here-document bodies (script text written to files is not a command line).
    static func withoutHeredocBodies(_ command: String) -> String {
        var kept: [Substring] = []
        var terminator: String?
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if let end = terminator {
                if line.trimmingCharacters(in: .whitespaces) == end {
                    terminator = nil
                }
                continue
            }
            kept.append(line)
            if let range = line.range(of: "<<") {
                let marker = line[range.upperBound...].drop { $0 == "-" || $0 == "~" || $0 == " " }
                let word = marker.prefix { !$0.isWhitespace && $0 != ";" && $0 != ")" }
                let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if !cleaned.isEmpty {
                    terminator = cleaned
                }
            }
        }
        return kept.joined(separator: "\n")
    }

    /// Top-level `amoo` subcommands (see `CLIApp.dispatchSubcommand`).
    static let cliSubcommands: Set = [
        "capabilities", "preflight", "device", "companion", "shots", "flow", "audit", "chat", "mcp", "studio",
        "generate", "env", "init", "probe", "doctor", "agent", "config", "credentials", "usage", "version", "help"
    ]

    /// Shell separators after which the next word is a command.
    private static let commandStarters: Set = [
        "&&",
        "||",
        ";",
        "|",
        "then",
        "do",
        "else",
        "time",
        "exec",
        "sudo",
        "env"
    ]

    /// The amoo subcommand of the first `amoo` invoked in command position (start of a pipeline
    /// segment, after `{`, `(`, `$(` or environment assignments), e.g. `device tap`.
    static func cliCommand(_ command: String) -> String? {
        let tokens = withoutHeredocBodies(command).split(separator: "\n")
            .flatMap { line in line.split(whereSeparator: \.isWhitespace).map(String.init) + [";"] }
        var atCommand = true
        for (index, raw) in tokens.enumerated() {
            // `A=$(amoo …)` and `$(amoo …)` start a command inside one shell word.
            let substituted = raw.range(of: "$(", options: .backwards).map { raw[$0.upperBound...] }
            let token = (substituted ?? raw[...]).drop { "{($`".contains($0) }
            if atCommand || substituted != nil, URL(fileURLWithPath: String(token)).lastPathComponent == "amoo" {
                let rest = Array(tokens[(index + 1)...])
                if let subcommand = TelemetryNaming.command(rest),
                   let first = subcommand.split(separator: " ").first, cliSubcommands.contains(String(first)) {
                    return subcommand
                }
                // A bare `amoo --flag` is a call; `amoo does …` in prose or a message is not.
                guard let first = rest.first?.trimmingCharacters(in: CharacterSet(charactersIn: ";&|)")) else {
                    return "amoo"
                }
                if first.hasPrefix("--"), first.dropFirst(2).allSatisfy({ $0.isLowercase || $0 == "-" }) {
                    return first
                }
                if first.hasPrefix("-") || first.hasPrefix(">") || first.hasPrefix("2>") {
                    return "amoo"
                }
            }
            let isAssignment = token.contains("=") && token.first?.isLetter == true && atCommand
            atCommand = commandStarters.contains(raw) || raw.hasSuffix(";") || raw.hasSuffix("&&")
                || ["{", "(", "$("].contains(raw) || isAssignment
        }
        return nil
    }

    // Parsing one transcript is a single linear pass over heterogenous records.
    // swiftlint:disable:next cyclomatic_complexity
    static func parse(_ data: Data) -> (turns: [Turn], results: [String: ResultSize]) {
        var turns: [Turn] = []
        var turnIndex: [String: Int] = [:]
        var results: [String: ResultSize] = [:]
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = entry["message"] as? [String: Any] else { continue }
            let type = entry["type"] as? String
            if type == "assistant", let id = message["id"] as? String {
                let usage = message["usage"] as? [String: Any] ?? [:]
                func number(_ key: String) -> Int {
                    (usage[key] as? NSNumber)?.intValue ?? 0
                }
                let index = turnIndex[id] ?? {
                    turns.append(Turn(messageID: id, timestamp: (entry["timestamp"] as? String).flatMap(parser.date)))
                    turnIndex[id] = turns.count - 1
                    return turns.count - 1
                }()
                turns[index].input = number("input_tokens")
                turns[index].cacheRead = number("cache_read_input_tokens")
                turns[index].cacheCreation = number("cache_creation_input_tokens")
                turns[index].output = number("output_tokens")
                for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                    if let toolID = block["id"] as? String, let name = block["name"] as? String {
                        let tool = amooTool(name: name, input: block["input"] as? [String: Any])
                        turns[index].toolUses.append(ToolUse(id: toolID, amooTool: tool))
                    }
                }
            } else if type == "user" {
                for block in message["content"] as? [[String: Any]] ?? []
                    where block["type"] as? String == "tool_result" {
                    guard let toolID = block["tool_use_id"] as? String else { continue }
                    var size = ResultSize()
                    if let text = block["content"] as? String {
                        size.characters = text.count
                    }
                    for item in block["content"] as? [[String: Any]] ?? [] {
                        if let text = item["text"] as? String {
                            size.characters += text.count
                        }
                        if item["type"] as? String == "image",
                           let source = item["source"] as? [String: Any], let base64 = source["data"] as? String {
                            size.images.append(ImageHeader.dimensions(base64: base64) ?? (0, 0))
                        }
                    }
                    results[toolID] = size
                }
            }
        }
        return (turns, results)
    }

    static func aggregate(files: [URL], since: Date?, into report: inout UsageReport) {
        var tokens = UsageReport.TokenUsage()
        var byTool: [String: UsageReport.ToolTokens] = [:]
        report.sources.transcripts = files.count
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let (turns, results) = parse(data)
            let usesAmoo = turns.contains { $0.toolUses.contains { $0.amooTool != nil } }
            guard usesAmoo else { continue }
            report.sources.transcriptsWithAmoo += 1
            tokens.transcripts += 1
            if file.pathComponents.contains("subagents") {
                tokens.subagentTranscripts += 1
            }
            for (index, turn) in turns.enumerated()
                where since.map({ (turn.timestamp ?? .distantFuture) >= $0 }) ?? true {
                tokens.assistantTurns += 1
                tokens.inputTokens += turn.input
                tokens.cacheReadTokens += turn.cacheRead
                tokens.cacheCreationTokens += turn.cacheCreation
                tokens.outputTokens += turn.output
                attribute(turns: turns, index: index, results: results, tokens: &tokens, byTool: &byTool)
            }
        }
        tokens.byTool = byTool.values.sorted { $0.carriedTokens > $1.carriedTokens }
        report.tokens = tokens
    }

    /// Shares the context growth after `turns[index]` among the tool results it produced.
    private static func attribute(
        turns: [Turn], index: Int, results: [String: ResultSize],
        tokens: inout UsageReport.TokenUsage, byTool: inout [String: UsageReport.ToolTokens]
    ) {
        let turn = turns[index]
        let gap = turn.toolUses.compactMap { use in results[use.id].map { (use, $0) } }
        guard !gap.isEmpty else { return }
        let estimates = gap.map { max(1, $0.1.estimatedTokens) }
        let estimateTotal = estimates.reduce(0, +)
        let measured = index + 1 < turns.count ? turns[index + 1].context - turn.context - turn.output : 0
        let laterTurns = max(0, turns.count - index - 1)
        for (offset, (use, size)) in gap.enumerated() {
            guard let tool = use.amooTool else { continue }
            let share = measured > 0 ? measured * estimates[offset] / estimateTotal : estimates[offset]
            let imageTokens = size.imageTokens
            tokens.amooToolResults += 1
            tokens.amooResultTokens += share
            tokens.amooCarriedTokens += share * laterTurns
            tokens.inlineImages += size.images.count
            tokens.inlineImageTokensEstimate += imageTokens
            var entry = byTool[tool] ?? UsageReport.ToolTokens(tool: tool)
            entry.results += 1
            entry.tokens += share
            entry.carriedTokens += share * laterTurns
            entry.images += size.images.count
            entry.imageTokensEstimate += imageTokens
            byTool[tool] = entry
        }
    }
}

/// Reads image dimensions from the first bytes of a base64 PNG or JPEG without decoding pixels.
enum ImageHeader {
    static func dimensions(base64: String) -> (width: Int, height: Int)? {
        let prefix = String(base64.prefix(65536))
        let padded = prefix + String(repeating: "=", count: (4 - prefix.count % 4) % 4)
        guard let data = Data(base64Encoded: String(padded.prefix(padded.count - padded.count % 4)))
            ?? Data(base64Encoded: String(prefix.prefix(prefix.count - prefix.count % 4)))
        else { return nil }
        return dimensions(data: [UInt8](data))
    }

    static func dimensions(data bytes: [UInt8]) -> (width: Int, height: Int)? {
        if bytes.count >= 24, bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            let width = bytes[16 ..< 20].reduce(0) { $0 << 8 | Int($1) }
            let height = bytes[20 ..< 24].reduce(0) { $0 << 8 | Int($1) }
            return (width, height)
        }
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 9 < bytes.count {
            guard bytes[index] == 0xFF else {
                index += 1
                continue
            }
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if (0xC0 ... 0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                return (width, height)
            }
            index += 2 + max(length, 2)
        }
        return nil
    }
}

// swiftlint:enable multiline_parameters
