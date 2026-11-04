// swiftlint:disable multiline_arguments
import Foundation
import MCP

extension DriverToolExecutor {
    public func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
        let started = ContinuousClock.now
        let result: ToolResult = if let invalid = MCPServer.validateArguments(tool: toolName, arguments: arguments) {
            invalid
        } else {
            await executeUnmeasured(toolName: toolName, arguments: arguments)
        }
        await measureResponse(tool: toolName, arguments: arguments, result: result, started: started)
        return result
    }

    func measureOperation(
        tool toolName: String, arguments: [String: String], result: ToolResult, started start: ContinuousClock.Instant
    ) async {
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

    func compactResult(_ original: ToolResult, tool: String, arguments: [String: String]) -> ToolResult {
        guard arguments["response_mode"] == "compact", !original.isError,
              original.structuredContent != nil else { return original }
        var result = original
        result.recordedContent = original.recordedContent ?? original.content
        result.content = "\(tool): ok"
        if tool == "find_elements", var fields = original.structuredContent?.objectValue,
           let rows = fields["elements"]?.arrayValue {
            fields["elements"] = .array(rows.map { row in
                guard let element = row.objectValue else { return row }
                return .object(element.filter { !["semantics", "bounds"].contains($0.key) })
            })
            result.structuredContent = .object(fields)
        }
        return result
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
