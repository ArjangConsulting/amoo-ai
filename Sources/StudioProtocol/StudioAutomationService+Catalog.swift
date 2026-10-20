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
           let deviceId = request.selectedDeviceId, let platform = request.platform, let elementSuggester {
            do {
                elements = try await elementSuggester.elements(deviceId: deviceId, platform: platform)
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
        guard let toolExecutor else {
            throw StudioAutomationError.invalidTest("Real device tool execution is unavailable in this Amoo build.")
        }
        let readOnly = grammar.tools[name]?.readOnly ?? false
        let operation = StudioToolOperation(id: "repl-\(UUID().uuidString)", tool: name, arguments: arguments)
        let platform = request.platform ?? request.activeTest.platform.rawValue
        logger.info("Console tool started", context: "tool=\(name) deviceId=\(deviceID)")
        do {
            let result = try await toolExecutor.execute(
                operation,
                deviceId: deviceID,
                platform: platform,
                appId: request.activeTest.requirements?.appId
            )
            if !readOnly {
                await elementSuggester?.invalidate(deviceId: deviceID)
            }
            logger.info("Console tool finished", context: "tool=\(name) deviceId=\(deviceID)")
            return .init(
                output: result.output,
                isError: false,
                tool: name,
                structuredContent: result.structuredContent,
                artifacts: result.artifacts
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await elementSuggester?.invalidate(deviceId: deviceID)
            logger.error("Console tool failed", error: error, context: "tool=\(name) deviceId=\(deviceID)")
            return .init(output: String(describing: error), isError: true, tool: name)
        }
    }
}
