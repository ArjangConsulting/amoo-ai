import AmooCore
import AmooLogging
import AmooTools
import Foundation
import ProcessRunner
import SwiftyShell

private let logger = AmooLogger.forType(FlowExtensionSession.self)

/// A flow tool owned by an extension program: `moq.select_variant` is step `select_variant` of the
/// program `amoo-ext-moq`. amoo knows nothing about what an extension does; see
/// `docs/flow-extensions.md` for the protocol.
struct FlowExtensionTool: Equatable {
    var prefix: String
    var step: String

    /// `nil` for a device tool or a flow-only step, which never contain a dot.
    init?(toolName: String) {
        let parts = toolName.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isName(parts[0]), Self.isName(parts[1]) else { return nil }
        prefix = String(parts[0])
        step = String(parts[1])
    }

    var executableName: String {
        "amoo-ext-\(prefix)"
    }

    private static func isName(_ part: Substring) -> Bool {
        guard let first = part.first, first.isASCII, first.isLowercase else { return false }
        return part.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "_" }
    }
}

/// The protocol version amoo speaks. An extension that answers with another version is rejected.
let flowExtensionProtocolVersion = 1

/// Runs one request against an extension program and returns its decoded reply.
protocol FlowExtensionInvoking: Sendable {
    func invoke(prefix: String, verb: String, request: Value, timeout: Swift.Duration) async throws -> Value
}

enum FlowExtensionError: Error, CustomStringConvertible, Equatable {
    case notFound(executable: String, searched: [String])
    case failed(executable: String, verb: String, exitCode: Int32, stderr: String)
    case malformedReply(executable: String, verb: String, detail: String)
    case unsupportedProtocol(executable: String, version: Int?)
    case unknownStep(tool: String, offered: [String])

    var description: String {
        switch self {
        case let .notFound(executable, searched):
            "Flow extension \(executable) is not installed: it is not on PATH or in AMOO_EXTENSION_PATH"
                + " (searched \(searched.count) directories). Install it, or put its directory in AMOO_EXTENSION_PATH."
        case let .failed(executable, verb, exitCode, stderr):
            "\(executable) \(verb) exited \(exitCode)"
                + (stderr.isEmpty ? "." : ": \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        case let .malformedReply(executable, verb, detail):
            "\(executable) \(verb) did not reply with a JSON object on stdout: \(detail)"
        case let .unsupportedProtocol(executable, version):
            "\(executable) speaks flow-extension protocol \(version.map(String.init) ?? "(none)"),"
                + " but this amoo speaks \(flowExtensionProtocolVersion)."
        case let .unknownStep(tool, offered):
            "\(tool) is not a step its extension offers. It offers: \(offered.sorted().joined(separator: ", "))."
        }
    }
}

/// Finds `amoo-ext-<prefix>` in `AMOO_EXTENSION_PATH`, then `PATH`, and runs it with the request on stdin.
struct ProcessFlowExtensionInvoker: FlowExtensionInvoking {
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var runner: any ProcessRunner = SystemProcessRunner()

    func executablePath(for prefix: String) throws -> String {
        let name = "amoo-ext-\(prefix)"
        let directories = searchDirectories()
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appending(path: name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw FlowExtensionError.notFound(executable: name, searched: directories)
    }

    func searchDirectories() -> [String] {
        let extra = environment["AMOO_EXTENSION_PATH"]?.split(separator: ":").map(String.init) ?? []
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (extra + path).map { ($0 as NSString).expandingTildeInPath }
    }

    func invoke(prefix: String, verb: String, request: Value, timeout: Swift.Duration) async throws -> Value {
        let executable = try executablePath(for: prefix)
        let name = "amoo-ext-\(prefix)"
        let body = try String(bytes: JSONEncoder().encode(request), encoding: .utf8) ?? "{}"
        let command = Command(executable).args([verb]).stdin(.string(body)).timeout(timeout)
        let result = try await runner.run(ProcessExecutionRequest(command: command, context: ShellContext()))
        guard result.exitCode == 0 else {
            throw FlowExtensionError.failed(
                executable: name, verb: verb, exitCode: result.exitCode, stderr: result.stderr
            )
        }
        let reply: Value
        do {
            reply = try JSONDecoder().decode(Value.self, from: Data(result.stdout.utf8))
        } catch {
            throw FlowExtensionError.malformedReply(executable: name, verb: verb, detail: "\(error)")
        }
        guard reply.objectValue != nil else {
            throw FlowExtensionError.malformedReply(executable: name, verb: verb, detail: "not an object")
        }
        return reply
    }
}

/// Identifies one flow run on one device to its extensions.
struct FlowExtensionRun: Sendable, Equatable {
    var id: String
    var flowPath: String?
    var outputDirectory: String?
    var platform: String
    var deviceID: String?

    var value: Value {
        var fields: [String: Value] = ["id": .string(id), "platform": .string(platform)]
        fields["flow"] = flowPath.map(Value.string)
        fields["output_dir"] = outputDirectory.map(Value.string)
        fields["device_id"] = deviceID.map(Value.string)
        return .object(fields)
    }
}

/// The extensions one flow run uses: their opaque state, and the launch environment and variables
/// they contributed. Each extension is described and started before the first step and ended after
/// the last one, so it can open and release per-run resources such as a mock-server session.
actor FlowExtensionSession {
    private let invoker: any FlowExtensionInvoking
    private let run: FlowExtensionRun
    private var states: [String: Value] = [:]
    private var started: [String] = []
    private(set) var launchEnvironment: [String: String] = [:]
    private(set) var variables: [String: String] = [:]

    init(invoker: any FlowExtensionInvoking, run: FlowExtensionRun) {
        self.invoker = invoker
        self.run = run
    }

    static let defaultTimeout = Swift.Duration.seconds(60)

    /// Describes and starts each of `prefixes`: the flow's declared extensions and those its `steps`
    /// use. Throws on the first one that is missing, speaks another protocol, does not offer a step,
    /// or fails to start; the ones already started are ended first.
    func start(prefixes: [String], steps: [FlowStep], variables flowVariables: [String: String]) async throws {
        let tools = steps.compactMap { FlowExtensionTool(toolName: $0.tool) }
        do {
            for prefix in prefixes {
                let offered = try await describe(prefix: prefix)
                for tool in tools where tool.prefix == prefix && !offered.contains(tool.step) {
                    throw FlowExtensionError.unknownStep(tool: "\(tool.prefix).\(tool.step)", offered: offered)
                }
                let reply = try await call(prefix: prefix, verb: "flow_start", fields: [
                    "vars": .object(flowVariables.mapValues(Value.string))
                ])
                started.append(prefix)
                try requireOK(reply, prefix: prefix, verb: "flow_start")
            }
        } catch {
            await end(passed: false)
            throw error
        }
    }

    /// The steps `prefix` offers, from its `describe` reply.
    func describe(prefix: String) async throws -> [String] {
        let reply = try await call(prefix: prefix, verb: "describe", fields: [:])
        let steps = reply.objectValue?["steps"]?.arrayValue ?? []
        return steps.compactMap { $0.stringValue ?? $0.objectValue?["name"]?.stringValue }
    }

    /// Runs one extension step. A failed or unreachable extension is a failed step, never a crash.
    func runStep(
        _ tool: FlowExtensionTool,
        name: String?,
        number: Int,
        arguments: Value
    ) async -> ToolResult {
        var timeout = Self.defaultTimeout
        if let milliseconds = arguments.objectValue?["timeout_ms"]?.intValue, milliseconds > 0 {
            timeout = max(timeout, .milliseconds(milliseconds) + .seconds(10))
        }
        do {
            var step: [String: Value] = [
                "tool": .string(tool.step), "number": .int(number), "arguments": arguments
            ]
            step["name"] = name.map(Value.string)
            let reply = try await call(
                prefix: tool.prefix,
                verb: "step",
                fields: ["step": .object(step)],
                timeout: timeout
            )
            let fields = reply.objectValue ?? [:]
            let message = fields["message"]?.stringValue ?? "\(tool.prefix).\(tool.step)"
            return ToolResult(
                content: message,
                isError: fields["ok"]?.boolValue != true,
                structuredContent: fields["result"]
            )
        } catch {
            logger.error(
                "Extension step failed",
                error: error,
                context: "action=step prefix=\(tool.prefix) step=\(tool.step)"
            )
            return .error("\(error)")
        }
    }

    /// Ends every started extension, newest first. An extension that fails to end is logged, not
    /// reported as a step: the run's result is already decided.
    func end(passed: Bool, appsLaunched: Int = 0, appTerminated: Bool = false) async {
        while let prefix = started.popLast() {
            do {
                let reply = try await call(prefix: prefix, verb: "flow_end", fields: [
                    "passed": .bool(passed),
                    "apps_launched": .int(appsLaunched),
                    "app_terminated": .bool(appTerminated)
                ])
                try requireOK(reply, prefix: prefix, verb: "flow_end")
            } catch {
                logger.error("Extension did not end cleanly", error: error, context: "action=flow_end prefix=\(prefix)")
            }
        }
    }

    private func call(
        prefix: String,
        verb: String,
        fields: [String: Value],
        timeout: Swift.Duration = defaultTimeout
    ) async throws -> Value {
        var request = fields
        request["protocol"] = .int(flowExtensionProtocolVersion)
        request["verb"] = .string(verb)
        request["run"] = run.value
        request["state"] = states[prefix] ?? .null
        logger.debug("Calling extension: prefix=\(prefix) verb=\(verb)")
        let reply = try await invoker.invoke(prefix: prefix, verb: verb, request: .object(request), timeout: timeout)
        let replyFields = reply.objectValue ?? [:]
        let version = replyFields["protocol"]?.intValue
        guard version == flowExtensionProtocolVersion else {
            throw FlowExtensionError.unsupportedProtocol(executable: "amoo-ext-\(prefix)", version: version)
        }
        if let state = replyFields["state"] {
            states[prefix] = state
        }
        for (key, value) in replyFields["launch_environment"]?.objectValue ?? [:] {
            launchEnvironment[key] = value.stringValue ?? value.jsonText
        }
        for (key, value) in replyFields["vars"]?.objectValue ?? [:] {
            variables[key] = value.stringValue ?? value.jsonText
        }
        logger.debug("Extension replied: prefix=\(prefix) verb=\(verb) ok=\(replyFields["ok"]?.boolValue ?? false)")
        return reply
    }

    private func requireOK(_ reply: Value, prefix: String, verb: String) throws {
        let fields = reply.objectValue ?? [:]
        guard fields["ok"]?.boolValue == true else {
            let message = fields["message"]?.stringValue ?? "no message"
            throw FlowExtensionError.failed(executable: "amoo-ext-\(prefix)", verb: verb, exitCode: 0, stderr: message)
        }
    }
}

extension Value {
    /// Compact JSON, for a non-string value that has to travel as text.
    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    /// Every string leaf passed through `transform`, so `${name}` resolves inside nested arguments.
    func mappingStrings(_ transform: (String) throws -> String) rethrows -> Self {
        switch self {
        case let .string(text): try .string(transform(text))
        case let .array(items): try .array(items.map { try $0.mappingStrings(transform) })
        case let .object(fields): try .object(fields.mapValues { try $0.mappingStrings(transform) })
        default: self
        }
    }
}
