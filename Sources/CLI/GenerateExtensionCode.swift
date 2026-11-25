import AmooCore
import AmooLogging
import AmooTools
import Foundation
import StudioProtocol

private let logger = AmooLogger.forType(ExtensionCodeError.self)

/// Asks one flow extension for test code: `amoo-ext-<prefix> emit`, with the request on stdin.
protocol FlowExtensionEmitting {
    func emit(prefix: String, request: Value) throws -> Value
}

/// Runs the extension program and waits for it; `amoo generate test` is a one-shot command, so a
/// blocking call costs nothing and keeps the command synchronous.
struct ProcessFlowExtensionEmitter: FlowExtensionEmitting {
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func emit(prefix: String, request: Value) throws -> Value {
        let path = try ProcessFlowExtensionInvoker(environment: environment).executablePath(for: prefix)
        let name = "amoo-ext-\(prefix)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["emit"]
        let input = Pipe()
        let output = Pipe()
        // stderr goes to a file, so a chatty extension cannot fill a pipe nothing reads yet.
        let errorsURL = FileManager.default.temporaryDirectory.appending(path: "amoo-ext-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorsURL) }
        let errors = try FileHandle(forWritingTo: errorsURL)
        defer { try? errors.close() }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        logger.debug("Asking extension for code: prefix=\(prefix)")
        let body = try JSONEncoder().encode(request)
        try process.run()
        // Written from another thread: a request larger than the pipe's buffer would otherwise block
        // here while the extension blocks writing its reply, which nothing reads yet.
        let writer = input.fileHandleForWriting
        DispatchQueue.global().async {
            try? writer.write(contentsOf: body)
            try? writer.close()
        }
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = (try? Data(contentsOf: errorsURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            throw FlowExtensionError.failed(
                executable: name,
                verb: "emit",
                exitCode: process.terminationStatus,
                stderr: String(bytes: stderr, encoding: .utf8) ?? ""
            )
        }
        let reply: Value
        do {
            reply = try JSONDecoder().decode(Value.self, from: stdout)
        } catch {
            throw FlowExtensionError.malformedReply(executable: name, verb: "emit", detail: "\(error)")
        }
        guard reply.objectValue?["protocol"]?.intValue == flowExtensionProtocolVersion else {
            throw FlowExtensionError.unsupportedProtocol(
                executable: name,
                version: reply.objectValue?["protocol"]?.intValue
            )
        }
        return reply
    }
}

/// Steps an extension said it cannot express in the target framework.
enum ExtensionCodeError: Error, CustomStringConvertible, Equatable {
    case cannotExpress([String])

    var description: String {
        switch self {
        case let .cannotExpress(refusals):
            "A flow extension cannot write code for \(refusals.count) part(s) of this test, so it would be"
                + " incomplete:\n" + refusals.map { "  - \($0)" }.joined(separator: "\n")
                + "\nPass --allow-incomplete to generate it with a failing statement in their place."
        }
    }
}

/// The test framework `emit` writes for, from the platform and UI toolkit the emitter targets.
func extensionFramework(platform: Platform, toolkit: UIToolkit) -> String {
    switch (platform, toolkit) {
    case (.android, .compose): "compose"
    case (.android, _): "espresso"
    default: "xcuitest"
    }
}

/// `test` with each flow extension's setup, step and teardown code attached, and each extension
/// operation replaced by one carrying its lines. A no-op for a plan that uses no extension.
///
/// An extension that answers `ok: false` cannot express that part in this framework. Without
/// `allowIncomplete` that refuses the whole test, as an uncompiled step does; with it, a failing
/// statement takes the step's place so the gap fails loudly at run time.
///
/// Each request carries `vars`: the flow's, as the plan recorded them, then `variables` (the
/// command's `--var`), the same set `amoo flow` sends at `flow_start`.
func attachingExtensionCode(
    to test: StudioAuthoredTest,
    framework: String,
    allowIncomplete: Bool,
    variables: [String: String] = [:],
    emitter: any FlowExtensionEmitting
) throws -> StudioAuthoredTest {
    guard let plan = test.compiledPlan, !plan.extensionPrefixes.isEmpty else { return test }
    let context = try test.testContext.map { try Value($0) } ?? .null
    let vars = Value.object((plan.vars ?? [:]).merging(variables) { _, override in override }.mapValues(Value.string))
    var code = StudioExtensionCode()
    var teardowns: [[String]] = []
    var refusals: [String] = []

    func ask(_ prefix: String, phase: String, step: Value? = nil) throws -> [String]? {
        var request: [String: Value] = [
            "protocol": .int(flowExtensionProtocolVersion), "verb": .string("emit"), "framework": .string(framework),
            "platform": .string(test.platform.rawValue), "phase": .string(phase), "test_context": context,
            "vars": vars
        ]
        request["step"] = step
        let reply = try emitter.emit(prefix: prefix, request: .object(request)).objectValue ?? [:]
        if reply["ok"]?.boolValue == false {
            let tool = step?.objectValue?["tool"]?.stringValue.map { "\(prefix).\($0)" } ?? "\(prefix) \(phase)"
            refusals.append("\(tool): \(reply["message"]?.stringValue ?? "no reason given")")
            return nil
        }
        for item in strings(reply["imports"]) where !code.imports.contains(item) {
            code.imports.append(item)
        }
        code.members += strings(reply["members"])
        let requires = strings(reply["requires"])
        code.requiresThrows = code.requiresThrows || requires.contains("throws")
        code.requiresAsync = code.requiresAsync || requires.contains("async")
        return strings(reply["lines"])
    }

    for prefix in plan.extensionPrefixes {
        code.setUp += try ask(prefix, phase: "setup") ?? []
        try teardowns.append(ask(prefix, phase: "teardown") ?? [])
    }
    code.tearDown = teardowns.reversed().flatMap(\.self)

    let operations = try (plan.toolOperations ?? []).map { operation -> StudioToolOperation in
        guard StudioExtensionCode.isExtensionTool(operation.tool) else { return operation }
        let parts = operation.tool.split(separator: ".").map(String.init)
        let arguments = operation.arguments[StudioExtensionCode.argumentsJSONArgument]
            .flatMap { try? JSONDecoder().decode(Value.self, from: Data($0.utf8)) }
            ?? .object(operation.arguments.mapValues(Value.string))
        let step: Value = .object(["tool": .string(parts[1]), "arguments": arguments])
        let lines = try ask(parts[0], phase: "step", step: step)
            ?? [failingStatement(framework: framework, message: "\(operation.tool) has no \(framework) equivalent")]
        return StudioToolOperation(
            id: operation.id,
            tool: StudioExtensionCode.operationTool,
            arguments: [StudioExtensionCode.codeArgument: lines.joined(separator: "\n")]
        )
    }
    if !refusals.isEmpty, !allowIncomplete {
        throw ExtensionCodeError.cannotExpress(refusals)
    }
    logger.info("Attached extension code: prefixes=\(plan.extensionPrefixes.count) refusals=\(refusals.count)")
    return test.attachingExtensionCode(code, operations: operations)
}

private func strings(_ value: Value?) -> [String] {
    value?.arrayValue?.compactMap(\.stringValue) ?? []
}

/// A statement that fails the generated test where an extension could not write code.
private func failingStatement(framework: String, message: String) -> String {
    let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return framework == "xcuitest"
        ? "XCTFail(\"\(escaped)\")"
        : "org.junit.Assert.fail(\"\(escaped.replacingOccurrences(of: "$", with: "\\$"))\")"
}
