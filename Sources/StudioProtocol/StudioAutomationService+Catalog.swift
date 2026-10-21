import Foundation

/// The catalog-backed console: the tool catalog, completion, validation, and running any console
/// tool. Active only when `amoo studio serve` supplies a `StudioToolCatalogProviding`; without one
/// the console keeps its original fixed command set.
public extension LiveStudioAutomationService {
    internal var grammar: StudioReplGrammar? {
        if let cachedGrammar {
            return cachedGrammar
        }
        guard let catalog = catalog() else { return nil }
        let built = StudioReplGrammar(catalog: catalog)
        cachedGrammar = built
        return built
    }

    private func catalog() -> StudioToolCatalog? {
        toolCatalogProvider.map { StudioToolCatalog(tools: $0.tools()) }
    }

    func toolCatalog() -> StudioToolCatalog? {
        catalog()
    }

    func complete(_ request: StudioReplCompletionRequest) async -> StudioReplCompletionResult {
        guard let grammar else { return .empty(at: request.cursor) }
        var elements: [StudioElementSuggestion] = []
        if grammar.needsElements(line: request.line, cursor: request.cursor),
           let deviceId = request.selectedDeviceId, let platform = request.platform {
            do {
                elements = try await suggestedElements(deviceId: deviceId, platform: platform)
            } catch {
                // Completion still offers enum values and names; element values are a bonus.
                logger.debug(
                    "Element suggestions unavailable",
                    context: "deviceId=\(deviceId) error=\(type(of: error))"
                )
            }
        }
        var devices: [StudioDevice] = []
        if case .builtinWord(slot: "<device>", _, _) = grammar.completionContext(
            line: request.line,
            cursor: request.cursor
        ) {
            devices = await workspace.listDevices()
        }
        return grammar.complete(line: request.line, cursor: request.cursor, elements: elements, devices: devices)
    }

    func validate(_ request: StudioReplValidationRequest) -> StudioReplValidationResult {
        .init(diagnostics: grammar?.diagnostics(for: request.line) ?? [])
    }

    /// Runs `command` through the catalog grammar. Returns nil for a built-in command, which the
    /// caller handles; throws the first error diagnostic for an invalid line.
    internal func catalogToolResult(
        _ command: String,
        request: StudioReplRequest,
        grammar: StudioReplGrammar
    ) async throws
        -> StudioReplResult? {
        let (parsed, diagnostics) = grammar.parse(command)
        if let problem = diagnostics.first(where: { $0.severity == .error }) {
            throw StudioAutomationError.invalidCommand(problem.message)
        }
        guard case let .tool(name, arguments) = parsed else { return nil }
        guard let deviceID = request.selectedDeviceId else {
            throw StudioAutomationError.invalidTest("Choose a device before running mobile commands.")
        }
        let readOnly = grammar.tools[name]?.readOnly ?? false
        if let recorded = await recordedToolResult(
            tool: name,
            arguments: arguments,
            readOnly: readOnly,
            deviceId: deviceID,
            request: request
        ) {
            return recorded
        }
        guard let toolExecutor else {
            throw StudioAutomationError.invalidTest("Real device tool execution is unavailable in this Amoo build.")
        }
        let operation = StudioToolOperation(id: "repl-\(UUID().uuidString)", tool: name, arguments: arguments)
        let target = ConsoleTarget(
            deviceId: deviceID,
            platform: request.platform ?? request.activeTest.platform.rawValue,
            appId: request.activeTest.requirements?.appId
        )
        logger.info("Console tool started", context: "tool=\(name) deviceId=\(deviceID)")
        let outcome: StudioReplResult
        do {
            let result = try await toolExecutor.execute(
                operation,
                deviceId: target.deviceId,
                platform: target.platform,
                appId: target.appId
            )
            logger.info("Console tool finished", context: "tool=\(name) deviceId=\(deviceID)")
            outcome = .init(
                output: result.output,
                isError: false,
                tool: name,
                structuredContent: result.structuredContent,
                artifacts: result.artifacts,
                screenshot: name == "take_screenshot" ? Self.screenshot(from: result) : nil,
                gesturePoint: Self.gesturePoint(
                    tool: name,
                    arguments: arguments,
                    structuredContent: result.structuredContent
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Console tool failed", error: error, context: "tool=\(name) deviceId=\(deviceID)")
            outcome = .init(output: String(describing: error), isError: true, tool: name)
        }
        guard !readOnly else { return outcome }
        await elementSuggester?.invalidate(deviceId: deviceID)
        guard request.captureScreenshot == true, outcome.screenshot == nil else { return outcome }
        return await outcome.with(screenshot: captureScreenshot(target: target, toolExecutor: toolExecutor))
    }

    private struct ConsoleTarget {
        let deviceId: String
        let platform: String
        let appId: String?
    }

    /// The screen after a console command. Waits for two identical frames, so the picture shows where
    /// an animation landed. A failed capture is logged and leaves the command's result unchanged.
    private func captureScreenshot(
        target: ConsoleTarget,
        toolExecutor: any StudioToolExecuting
    ) async -> StudioScreenshot? {
        let operation = StudioToolOperation(
            id: "repl-screen-\(UUID().uuidString)",
            tool: "take_screenshot",
            arguments: ["settle_timeout_ms": "1500"]
        )
        do {
            let result = try await toolExecutor.execute(
                operation,
                deviceId: target.deviceId,
                platform: target.platform,
                appId: target.appId
            )
            return Self.screenshot(from: result)
        } catch {
            logger.error("Console screenshot failed", error: error, context: "deviceId=\(target.deviceId)")
            return nil
        }
    }

    static func screenshot(from result: StudioToolExecutionResult) -> StudioScreenshot? {
        guard let path = result.artifacts.first(where: { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") })
        else { return nil }
        let fields = result.structuredContent.flatMap(jsonObject) ?? [:]
        return .init(
            path: path,
            widthPixels: fields["width_pixels"] as? Int,
            heightPixels: fields["height_pixels"] as? Int,
            widthPoints: fields["width_points"] as? Double,
            heightPoints: fields["height_points"] as? Double,
            scale: fields["scale"] as? Double
        )
    }

    /// Coordinate gestures report their arguments; `tap_element` reports the verified `tap_point`.
    static func gesturePoint(tool: String, arguments: [String: String], structuredContent: String?) -> StudioPoint? {
        if ["tap", "double_tap", "long_press"].contains(tool),
           let x = arguments["x"].flatMap(Double.init), let y = arguments["y"].flatMap(Double.init) {
            return .init(x: x, y: y)
        }
        guard let point = structuredContent.flatMap(jsonObject)?["tap_point"] as? [String: Any],
              let x = (point["x"] as? NSNumber)?.doubleValue, let y = (point["y"] as? NSNumber)?.doubleValue
        else { return nil }
        return .init(x: x, y: y)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

extension StudioReplResult {
    func with(screenshot: StudioScreenshot?) -> Self {
        .init(
            output: output,
            isError: isError,
            tool: tool,
            structuredContent: structuredContent,
            artifacts: artifacts,
            screenshot: screenshot,
            gesturePoint: gesturePoint
        )
    }
}
