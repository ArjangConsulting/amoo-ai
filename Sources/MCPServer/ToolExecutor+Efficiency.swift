// swiftlint:disable multiline_arguments
import AmooTelemetry
import Foundation
import MCP
import Tracing

extension DriverToolExecutor {
    /// Runs one tool call for every surface (MCP, CLI, flows) inside an OpenTelemetry
    /// `execute_tool <name>` span, and records the run-level cost entry.
    public func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
        await withSpan("execute_tool \(toolName)", ofKind: .internal) { span in
            await executeMeasured(toolName: toolName, arguments: arguments, span: span)
        }
    }

    private func executeMeasured(
        toolName: String, arguments: [String: String], span: any Tracing.Span
    ) async -> ToolResult {
        let started = ContinuousClock.now
        let runID = runIdentity(arguments: arguments)
        let call = await runTelemetry.begin(runID: runID, tool: toolName, sessionID: arguments["session_id"])
        var result = await RunCallIdentity.$current.withValue(call) {
            if let invalid = MCPServer.validateArguments(tool: toolName, arguments: arguments) {
                return invalid
            }
            return await self.executeUnmeasured(toolName: toolName, arguments: arguments)
        }
        if toolName == "start_session" {
            var fields = result.structuredContent?.objectValue ?? [:]
            fields["run_id"] = .string(runID)
            result.structuredContent = .object(fields)
            if let id = fields["session_id"]?.stringValue {
                sessionRuns[id] = runID
            }
        }
        result = flagRepeatedCall(result, tool: toolName, arguments: arguments)
        var textResult = result
        textResult.image = nil
        await runTelemetry.finish(
            call, failed: result.isError,
            sessionID: arguments["session_id"] ?? result.structuredContent?.objectValue?["session_id"]?.stringValue,
            metrics: [
                "elapsed_ms": Self.elapsedMilliseconds(since: started),
                "wire_response_bytes": (try? JSONEncoder().encode(result.mcpResult()).count) ?? 0,
                "text_payload_bytes": (try? JSONEncoder().encode(textResult.mcpResult()).count) ?? 0,
                "image_bytes": result.image?.data.count ?? 0,
                "image_pixels": result.image == nil ? 0 : Self.imagePixels(result)
            ]
        )
        await measureResponse(tool: toolName, arguments: arguments, result: result, started: started)
        Self.annotate(span, tool: toolName, arguments: arguments, result: result, runID: runID)
        span.attributes[TelemetryAttribute.callID] = call.callID
        return result
    }

    static func annotate(
        _ span: any Tracing.Span, tool: String, arguments: [String: String], result: ToolResult, runID: String
    ) {
        let fields = result.structuredContent?.objectValue ?? [:]
        var textResult = result
        textResult.image = nil
        span.updateAttributes { attributes in
            attributes[TelemetryAttribute.genAIOperationName] = "execute_tool"
            attributes[TelemetryAttribute.genAIToolName] = tool
            attributes[TelemetryAttribute.runID] = runID
            let context = TelemetryCallContext.current
            attributes[TelemetryAttribute.client] = context?.surface ?? "library"
            if let name = context?.clientName {
                attributes[TelemetryAttribute.clientName] = name
            }
            if let session = arguments["session_id"] ?? fields["session_id"]?.stringValue {
                attributes[TelemetryAttribute.sessionID] = session
            }
            attributes[TelemetryAttribute.responseMode] = arguments["response_mode"] ?? "default"
            attributes[TelemetryAttribute.responseBytes] = (try? JSONEncoder().encode(result.mcpResult()).count) ?? 0
            attributes[TelemetryAttribute.responseTextBytes] =
                (try? JSONEncoder().encode(textResult.mcpResult()).count) ?? 0
            attributes[TelemetryAttribute.observedElements] = result.observedElements.count
            let inline = result.image != nil
            attributes[TelemetryAttribute.imageInline] = inline
            if inline || fields["saved_path"] != nil {
                attributes[TelemetryAttribute.imageBytes] = result.image?.data.count ?? fields["byte_count"]?
                    .intValue ?? 0
                if let width = fields["width_pixels"].flatMap({ Double($0.description) }),
                   let height = fields["height_pixels"].flatMap({ Double($0.description) }) {
                    attributes[TelemetryAttribute.imageWidth] = Int(width)
                    attributes[TelemetryAttribute.imageHeight] = Int(height)
                }
                if let scale = fields["image_scale"]?.doubleValue {
                    attributes[TelemetryAttribute.imageScale] = scale
                }
            }
            if let frames = fields["settle_frames"]?.intValue {
                attributes[TelemetryAttribute.settleFrames] = frames
            }
            if fields["repeated_call"] == .bool(true) {
                attributes[TelemetryAttribute.repeatedCall] = true
            }
        }
        if result.isError {
            let code = fields["code"]?.stringValue ?? fields["failure_kind"]?.stringValue ?? "tool_error"
            span.attributes[TelemetryAttribute.errorType] = code
            span.setStatus(SpanStatus(code: .error, message: code))
        }
    }

    func measureOperation(
        tool toolName: String, arguments: [String: String], result: ToolResult, started start: ContinuousClock.Instant
    ) async {
        if let call = RunCallIdentity.current, !Self.controlPlaneTools.contains(toolName), toolName != "run_steps" {
            let saved = result.structuredContent?.objectValue?["saved_path"] != nil
            await runTelemetry.operation(
                call, milliseconds: Self.elapsedMilliseconds(since: start),
                recovery: ["device_install_app", "device_launch_app", "device_uninstall_app", "device_wake"]
                    .contains(toolName),
                evidenceBytes: saved ? result.structuredContent?.objectValue?["byte_count"]?.intValue ?? 0 : 0,
                pixels: saved ? Self.imagePixels(result) : 0
            )
        }
        if let id = arguments["session_id"], let session = await sessionManager?.session(id),
           !Self.controlPlaneTools.contains(toolName), toolName != "run_steps" {
            await session.recordOperation(
                milliseconds: Self.elapsedMilliseconds(since: start),
                recovery: ["device_install_app", "device_launch_app", "device_uninstall_app"].contains(toolName),
                evidenceImageBytes: result.structuredContent?.objectValue?["saved_path"] == nil
                    ? 0 : result.structuredContent?.objectValue?["byte_count"]?.intValue ?? 0,
                dimensions: Self.imageDimensions(result)
            )
        }
    }

    static func screenshotDimensionFields(_ data: Data) -> [String: Value] {
        guard let dimensions = ScreenshotScaler.dimensions(data) else { return [:] }
        return ["width_pixels": .int(dimensions.width), "height_pixels": .int(dimensions.height)]
    }

    static func imageDimensions(_ result: ToolResult) -> String? {
        let fields = result.structuredContent?.objectValue ?? [:]
        return fields["width_pixels"].flatMap { width in
            fields["height_pixels"].map { "\(width)x\($0)" }
        }
    }

    static func elapsedMilliseconds(since started: ContinuousClock.Instant) -> Int {
        let duration = started.duration(to: .now).components
        return Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    /// Shapes a result for the model. Clients such as Claude Code hand the model `structuredContent`,
    /// so element rows there are compacted by default: no semantics or bounds, default-valued fields
    /// (`id: ""`, `visible: true`, `enabled: true`, `selected: false`) omitted, coordinates rounded.
    /// `response_mode=full` keeps everything; `response_mode=compact` also shortens the text summary.
    func compactResult(_ original: ToolResult, tool: String, arguments: [String: String]) -> ToolResult {
        let mode = arguments["response_mode"] ?? "default"
        guard mode != "full", let fields = original.structuredContent?.objectValue else { return original }
        var result = original
        result.structuredContent = .object(Self.compactElementRows(fields))
        if mode == "compact", !original.isError {
            result.recordedContent = original.recordedContent ?? original.content
            result.content = "\(tool): ok"
        }
        return result
    }

    /// `tap_element` fields omitted under `response_mode=compact` while they hold these values. They
    /// are the same on nearly every tap (`hittability_checked` is always false on Android, whose
    /// inspection is a flat list), and `outcome_status` already says the postcondition is unverified.
    static let defaultTapFields: [String: Value] = [
        "postcondition_verified": .bool(false),
        "hittability_checked": .bool(false),
        "visual_change": .string("unverified"),
        "target_state": .null,
        "element_label": .string("")
    ]

    /// Drops ``defaultTapFields`` from a successful compact `tap_element` result; a missing field
    /// means its default. Default and full modes keep them.
    static func omittingDefaultTapFields(
        _ result: ToolResult,
        tool: String,
        arguments: [String: String]
    ) -> ToolResult {
        guard tool == "tap_element", arguments["response_mode"] == "compact", !result.isError,
              let fields = result.structuredContent?.objectValue else { return result }
        var compact = result
        compact.structuredContent = .object(fields.filter { key, value in defaultTapFields[key] != value })
        return compact
    }

    /// Marks a mutating call identical to the previous one in the same session (`repeated_call`,
    /// `repeat_count`, `repeat_hint`): repeats were the most common retry pattern in recorded runs,
    /// usually a swipe looking for something or a tap whose effect went unchecked.
    func flagRepeatedCall(_ result: ToolResult, tool: String, arguments: [String: String]) -> ToolResult {
        guard !ToolCatalogMetadata.isReadOnly(tool), !Self.controlPlaneTools.contains(tool), tool != "run_steps"
        else { return result }
        let ignored: Set = ["session_id", "run_id", "response_mode", "check_id"]
        let signature = tool + "|" + arguments.filter { !ignored.contains($0.key) }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let key = arguments["session_id"] ?? "default"
        let count = lastMutatingCall[key]?.signature == signature ? (lastMutatingCall[key]?.count ?? 0) + 1 : 1
        lastMutatingCall[key] = (signature, count)
        guard count >= 2, var fields = result.structuredContent?.objectValue else { return result }
        fields["repeated_call"] = .bool(true)
        fields["repeat_count"] = .int(count)
        fields["repeat_hint"] = .string(
            ["swipe", "swipe_in_direction", "scroll", "drag"].contains(tool)
                ? "Identical \(tool) \(count) times in a row; scroll_to_element reaches a target in one call."
                : "Identical \(tool) \(count) times in a row; check the previous outcome before repeating."
        )
        var flagged = result
        flagged.structuredContent = .object(fields)
        return flagged
    }

    /// Keys whose arrays hold element rows.
    static let elementRowKeys: Set = ["elements", "available_controls", "interactable_elements", "matches"]

    static func compactElementRows(_ fields: [String: Value]) -> [String: Value] {
        fields.mapValuesWithKeys { key, value in
            guard elementRowKeys.contains(key), let rows = value.arrayValue else { return value }
            return .array(rows.map { row in row.objectValue.map { .object(compactRow($0)) } ?? row })
        }
    }

    static func compactRow(_ row: [String: Value]) -> [String: Value] {
        var compact: [String: Value] = [:]
        for (key, value) in row {
            switch (key, value) {
            case ("semantics", _), ("bounds", _),
                 ("id", .string("")), ("visible", .bool(true)), ("enabled", .bool(true)),
                 ("selected", .bool(false)), ("checkable", .bool(false)):
                continue
            case let ("x", .double(number)), let ("y", .double(number)):
                compact[key] = .double((number * 10).rounded() / 10)
            default:
                compact[key] = value
            }
        }
        return compact
    }

    func measureResponse(
        tool: String, arguments: [String: String], result: ToolResult, started: ContinuousClock.Instant
    ) async {
        let id = arguments["session_id"] ?? result.structuredContent?.objectValue?["session_id"]?.stringValue
        guard let id, let session = await sessionManager?.session(id) else { return }
        await session.recordClientResponse(
            bytes: (try? JSONEncoder().encode(result.mcpResult()).count) ?? 0,
            imageBytes: result.image?.data.count ?? 0, dimensions: nil
        )
        if tool == "start_session" {
            await session.recordSetup(milliseconds: Self.elapsedMilliseconds(since: started))
        }
        await sessionManager?.persist(id)
    }
}

// swiftlint:enable multiline_arguments

extension Dictionary {
    func mapValuesWithKeys(_ transform: (Key, Value) -> Value) -> [Key: Value] {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
