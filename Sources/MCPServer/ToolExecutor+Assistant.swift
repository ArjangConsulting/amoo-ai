import AmooCore
import AuditEngine
import Foundation
import MCP
import TestSession

extension DriverToolExecutor {
    // MARK: - Assistant Tool Execution

    func executeDescribeScreen(driver: any PlatformDriver) async throws -> ToolResult {
        let observation = try await driver.observeScreen()
        let context = observation.context
        let hierarchy = observation.hierarchy
        let interactable = observation.interactableElements
        let description = formatScreenDescription(
            context: context,
            hierarchy: hierarchy,
            interactableElements: interactable
        )
        let report = ScreenDescriptionReport(
            summary: context.summary,
            screenTitle: context.screenTitle?.isEmpty == false ? context.screenTitle : nil,
            interactableCount: interactable.count
        )
        var fields = try Value(report).objectValue ?? [:]
        fields["actions"] = .array(interactable.prefix(7).map(elementFields))
        fields["has_more"] = .bool(interactable.count > 7)
        fields["screen_token"] = .string(observation.token)
        return .success(description, structuredContent: .object(fields))
    }

    func executeSuggestActions(driver: any PlatformDriver) async throws -> ToolResult {
        let report = try await buildSuggestionReport(driver: driver)
        return try .success(formatSuggestionReport(report), structuredContent: Value(report))
    }

    func buildSuggestionReport(driver: any PlatformDriver) async throws -> TestActionSuggestionReport {
        let observation = try await driver.observeScreen()
        let context = observation.context
        let hierarchy = observation.hierarchy
        let allElements = observation.elements
        let interactable = observation.interactableElements
        let filteredElements = filterAppRelevantElements(interactable)
        let diagnostics = collectAccessibilityDiagnostics(
            allElements: allElements,
            interactableElements: filteredElements
        )
        let developerFeedback = developerFeedback(for: diagnostics)
        let request = TestActionSuggestionRequest(
            context: enrichedScreenContext(
                context: context,
                allElements: allElements,
                interactableElements: filteredElements,
                hierarchy: hierarchy
            ),
            hierarchy: hierarchy,
            allElements: filterAppRelevantElements(allElements),
            interactableElements: filteredElements,
            diagnostics: diagnostics,
            developerFeedback: developerFeedback,
            screenshot: nil
        )

        return deterministicSuggestionReport(for: request)
    }

    func executeAnalyzeAITestability(driver: any PlatformDriver) async throws -> ToolResult {
        let context = try await driver.getScreenContext()
        let allElements = try await driver.findElements(ElementSelector())
        let interactable = try await filterAppRelevantElements(driver.getInteractableElements())
        let diagnostics = collectAccessibilityDiagnostics(allElements: allElements, interactableElements: interactable)
        let elementsWithIssues = collectElementA11yIssues(allElements: allElements, interactableElements: interactable)
        let report = AITestabilityReport(
            screenSummary: context.summary,
            interactableCount: interactable.count,
            confidence: testabilityConfidence(diagnostics: diagnostics, interactableCount: interactable.count),
            diagnostics: diagnostics,
            developerFeedback: developerFeedback(for: diagnostics),
            elementsWithIssues: elementsWithIssues
        )

        return try .success(formatAITestabilityReport(report), structuredContent: Value(report))
    }

    func executeHighlightA11yIssues(driver: any PlatformDriver) async throws -> ToolResult {
        async let hierarchyTask = driver.getViewHierarchy()
        async let allElementsTask = driver.findElements(ElementSelector())
        async let interactableTask = driver.getInteractableElements()
        async let screenshotTask = driver.takeScreenshot(format: .png)

        let hierarchy = try await hierarchyTask
        let allElements = try await allElementsTask
        let interactable = try await filterAppRelevantElements(interactableTask)
        let screenshotData = try await screenshotTask

        let issues = collectElementA11yIssues(allElements: allElements, interactableElements: interactable)

        let viewportWidth = hierarchy.frame?.width ?? 0
        let pngData = Data(screenshotData.bytes)
        let annotated = ScreenshotAnnotator.annotate(
            pngData: pngData,
            issues: issues,
            viewportWidth: viewportWidth
        )

        struct HighlightReport: Codable {
            let issueCount: Int
            let issues: [ElementA11yIssue]
        }
        let report = HighlightReport(issueCount: issues.count, issues: issues)

        let text: String
        if issues.isEmpty {
            text = "No accessibility issues found — nothing to highlight."
        } else {
            let lines = issues.map { issue in
                let typeStr = issue.type.map { " [\($0)]" } ?? ""
                let idStr = issue.id.isEmpty ? "(no id)" : issue.id
                let frameStr = issue.frame
                    .map { frame in " at (\(Int(frame.x)),\(Int(frame.y))) \(Int(frame.width))×\(Int(frame.height))pt" }
                    ?? ""
                return "  \(idStr)\(typeStr)\(frameStr) — \(issue.issue)"
            }
            text = "\(issues.count) element(s) highlighted (red=missing label, orange=generic, yellow=duplicate):\n"
                + lines.joined(separator: "\n")
        }

        return try ToolResult(
            content: text,
            structuredContent: Value(report),
            image: annotated.map { ToolImageContent(data: $0, mimeType: ImageFormat.png.mimeType) }
        )
    }

    func executeFindByDescription(
        _ description: String,
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let allElements = try await driver.findElements(ElementSelector())
        let lowered = description.lowercased()
        let directMatches = allElements.filter { element in
            element.label.lowercased().contains(lowered) || element.id.lowercased().contains(lowered)
        }
        let matches = directMatches.isEmpty ? try await driver.findByDescription(description) : directMatches
        let report = ElementDescriptionMatchReport(
            query: description,
            matches: matches.map { ElementMatch(id: $0.id, label: $0.label, type: $0.type?.rawValue) }
        )

        if matches.isEmpty {
            return try .success("No elements matched: \(description)", structuredContent: Value(report))
        }
        let descriptions = matches.map { "[\($0.id)] \($0.label)" }
        return try .success(
            "Found \(matches.count) match(es):\n\(descriptions.joined(separator: "\n"))",
            structuredContent: Value(report)
        )
    }

    // Image capture, optional file output, and geometry share one response boundary.
    // swiftlint:disable:next function_body_length
    func executeTakeScreenshot(
        driver: any PlatformDriver,
        arguments: [String: String]
    ) async throws -> ToolResult {
        guard boolArgument(arguments["return_image"]) != false || arguments["output"]?.isEmpty == false else {
            throw ToolExecutionError(code: "invalid_argument", message: "output is required when return_image=false")
        }
        let requestedFormat = ImageFormat(parsing: arguments["format"])
        let screenshot = try await driver.takeScreenshot(format: requestedFormat)
        // Trust the format the driver actually produced — some drivers ignore the
        // requested format (e.g. Android always returns PNG), so labeling by the
        // request would hand clients a wrong MIME type.
        let actualFormat = screenshot.format
        let originalData = Data(screenshot.bytes)

        // Downscaling is the single biggest lever on how much a screenshot costs a model to read:
        // a full-resolution phone screen runs into thousands of tokens, and most questions
        // ("which screen am I on", "did the sheet close") are answerable at half scale.
        let scale = arguments["scale"].flatMap(Double.init)
        let scaledData = ScreenshotScaler.scaled(originalData, by: scale, format: actualFormat)
        let data = scaledData ?? originalData

        var fields: [String: Value] = [
            "byte_count": .int(data.count),
            "format": .string(actualFormat.rawValue)
        ]
        if data.count != originalData.count {
            fields["original_byte_count"] = .int(originalData.count)
        }

        // The image is in pixels and gestures take points. Reporting both, and the factor between
        // them, is what stops a position read off this image from being passed straight to `tap`
        // — which lands off-screen and still reports success.
        var geometryNote = ""
        if let screen = try? await driver.screenGeometry(), screen.scale > 0 {
            let imageScale = scaledData == nil ? 1 : (scale ?? 1)
            let imageWidth = (screen.widthPixels * imageScale).rounded()
            let imageHeight = (screen.heightPixels * imageScale).rounded()
            let imagePixelsPerPoint = screen.scale * imageScale
            fields["width_pixels"] = .double(imageWidth)
            fields["height_pixels"] = .double(imageHeight)
            fields["width_points"] = .double(screen.widthPoints)
            fields["height_points"] = .double(screen.heightPoints)
            fields["scale"] = .double(imagePixelsPerPoint)
            geometryNote = " — image is \(Int(imageWidth))x\(Int(imageHeight))px;"
                + " gestures take points (\(Int(screen.widthPoints))x\(Int(screen.heightPoints))),"
                + " so divide image coordinates by \(imagePixelsPerPoint.formatted())"
            if scaledData == nil {
                geometryNote += " or pass unit=pixels"
            } else {
                geometryNote += "; unit=pixels expects native screenshot pixels"
            }
        }

        var savedNote = ""
        if let output = arguments["output"], !output.isEmpty {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            do {
                try data.write(to: url)
                fields["saved_path"] = .string(url.path)
                savedNote = " — saved to \(url.path)"
            } catch {
                // Keep the declared outputSchema's required fields even on error,
                // for clients that validate structured content strictly.
                return ToolResult(
                    content: "take_screenshot captured \(data.count) bytes but failed to write to \(output): \(error)",
                    isError: true,
                    structuredContent: .object(fields)
                )
            }
        }

        // Surface format downgrades instead of leaving them silent — the request
        // is best-effort (see ScreenCapture.takeScreenshot).
        let formatNote = actualFormat == requestedFormat
            ? ""
            : " — note: requested \(requestedFormat.rawValue) but the driver produced \(actualFormat.rawValue)"

        return ToolResult(
            content: "Screenshot captured: \(data.count) bytes (\(actualFormat.rawValue))"
                + "\(savedNote)\(formatNote)\(geometryNote)",
            structuredContent: .object(fields),
            image: boolArgument(arguments["return_image"]) == false
                ? nil : ToolImageContent(data: data, mimeType: actualFormat.mimeType)
        )
    }
}
