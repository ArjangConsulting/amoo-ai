import Foundation

/// `amoo usage report`: where agent tokens and wall-clock time go, joined from amoo's own
/// OpenTelemetry spans (or the run ledger for older data), recorded session reports and plans,
/// and the AI client's transcripts (real token usage). Counts and ids only — never content.
struct UsageReport: Codable, Equatable {
    var schemaVersion = 1
    var generatedAt: String
    var window: Window
    var sources: Sources
    var tools: [ToolUsage] = []
    var rpcs: [RPCUsage] = []
    var processes: [ProcessUsage] = []
    var phases: [PhaseUsage] = []
    var retries = RetrySignals()
    var errors: [ErrorCount] = []
    var codegen = CodegenHealth()
    var tokens: TokenUsage?
    var recommendations: [String] = []

    struct Window: Codable, Equatable {
        var since: String?
        var runID: String?
    }

    struct Sources: Codable, Equatable {
        /// `spans` when OpenTelemetry spans cover the window, otherwise `run-ledger`.
        var latencySource = "none"
        var traceFiles = 0
        var spans = 0
        var ledgerCalls = 0
        var sessions = 0
        var plans = 0
        var transcripts = 0
        var transcriptsWithAmoo = 0
    }

    struct ToolUsage: Codable, Equatable {
        var tool: String
        var calls = 0
        var failures = 0
        var p50Ms = 0
        var p95Ms = 0
        var maxMs = 0
        var totalMs = 0
        var responseBytes = 0
        var textBytes = 0
        var inlineImages = 0
        var inlineImageBytes = 0
        var inlineImagePixels = 0
        var savedImages = 0
        var repeatedCalls = 0
        var compactCalls = 0
        var surfaces: [String: Int] = [:]
    }

    struct RPCUsage: Codable, Equatable {
        var method: String
        var calls = 0
        var failures = 0
        var p50Ms = 0
        var p95Ms = 0
        /// Median time the companion itself spent (from `amoo-server-ms`), when reported.
        var serverP50Ms: Int?
        /// Median of client time minus companion time: transport, encoding and queuing.
        var overheadP50Ms: Int?
    }

    struct ProcessUsage: Codable, Equatable {
        var command: String
        var calls = 0
        var failures = 0
        var p50Ms = 0
        var p95Ms = 0
        var totalMs = 0
    }

    struct PhaseUsage: Codable, Equatable {
        var phase: String
        var count = 0
        var p50Ms = 0
        var p95Ms = 0
        var totalMs = 0
    }

    struct RetrySignals: Codable, Equatable {
        var sessions = 0
        /// The same tool with the same arguments called back to back.
        var identicalConsecutive: [String: Int] = [:]
        /// A failed call followed by an inspection (find_elements, describe_screen, …).
        var failedThenInspected: [String: Int] = [:]
        /// A failed call retried with the same tool within the next three calls.
        var failedThenRetried: [String: Int] = [:]
        var selectorMisses = 0
        var transportFailures = 0
        var timeouts = 0
        var startupAttempts = 0
        var failedStartups = 0
    }

    struct ErrorCount: Codable, Equatable {
        var tool: String
        var message: String
        var count: Int
    }

    struct CodegenHealth: Codable, Equatable {
        var plans = 0
        var plansWithSteps = 0
        var steps = 0
        var warnings: [String: Int] = [:]
        /// Warnings that put generated-test reliability at risk, per plan with steps.
        var riskPerPlan = 0.0
    }

    struct TokenUsage: Codable, Equatable {
        var transcripts = 0
        var subagentTranscripts = 0
        var assistantTurns = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cacheCreationTokens = 0
        var amooToolResults = 0
        /// Context growth measured between assistant turns, attributed to amoo tool results.
        var amooResultTokens = 0
        /// `amooResultTokens` re-read on every later turn of the same transcript (mostly cache reads).
        var amooCarriedTokens = 0
        var inlineImages = 0
        var inlineImageTokensEstimate = 0
        var byTool: [ToolTokens] = []
    }

    struct ToolTokens: Codable, Equatable {
        var tool: String
        var results = 0
        var tokens = 0
        var carriedTokens = 0
        var images = 0
        var imageTokensEstimate = 0
    }
}

enum UsageStatistics {
    /// Nearest-rank percentile of `values` in `fraction` (0...1); 0 for an empty list.
    static func percentile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count) * fraction).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// Error text with numbers collapsed so the same failure groups together.
    static func normalizedMessage(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        var output = ""
        var lastWasDigit = false
        for character in firstLine.prefix(90) {
            if character.isNumber {
                if !lastWasDigit {
                    output.append("N")
                }
                lastWasDigit = true
            } else {
                output.append(character)
                lastWasDigit = false
            }
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    /// Claude's documented image cost: images are downscaled to fit a 1568 px long edge and
    /// about 1.15 megapixels, then cost roughly `width × height / 750` tokens.
    static func imageTokens(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        var scaledWidth = Double(width)
        var scaledHeight = Double(height)
        let longEdge = max(scaledWidth, scaledHeight)
        if longEdge > 1568 {
            scaledWidth *= 1568 / longEdge
            scaledHeight *= 1568 / longEdge
        }
        let pixels = scaledWidth * scaledHeight
        if pixels > 1_150_000 {
            let factor = (1_150_000 / pixels).squareRoot()
            scaledWidth *= factor
            scaledHeight *= factor
        }
        return Int((scaledWidth * scaledHeight / 750).rounded())
    }
}
