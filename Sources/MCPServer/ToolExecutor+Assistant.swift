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
        fields["actions"] = .array(interactable.prefix(7).map { elementFields($0) })
        fields["has_more"] = .bool(interactable.count > 7)
        fields["screen_token"] = .string(observation.token)
        return .success(description, structuredContent: .object(fields))
    }

    func executeSuggestActions(driver: any PlatformDriver) async throws -> ToolResult {
        let report = try await buildSuggestionReport(driver: driver)
        return try .success(formatSuggestionReport(report), structuredContent: assistantDiagnosticFields(Value(report)))
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
        let observation = try await driver.observeScreen()
        let context = observation.context
        let allElements = observation.elements
        let interactable = filterAppRelevantElements(observation.interactableElements)
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

        return try .success(
            formatAITestabilityReport(report),
            structuredContent: assistantDiagnosticFields(Value(report))
        )
    }

    func executeHighlightA11yIssues(driver: any PlatformDriver) async throws -> ToolResult {
        let observation = try await driver.observeScreen()
        let hierarchy = observation.hierarchy
        let allElements = observation.elements
        let interactable = filterAppRelevantElements(observation.interactableElements)
        let screenshotData = try await driver.takeScreenshot(format: .png)
        let after = try await driver.observeScreen()

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
            text = "No naming concerns detected in the captured elements."
                + " Other accessibility properties are unassessed."
        } else {
            let lines = issues.map { issue in
                let typeStr = issue.type.map { " [\($0)]" } ?? ""
                let idStr = issue.id.isEmpty ? "(no id)" : issue.id
                let frameStr = issue.frame
                    .map { frame in
                        " at (\(frame.x),\(frame.y)) bounds \(frame.width)×\(frame.height) in capture units"
                    }
                    ?? ""
                return "  \(idStr)\(typeStr)\(frameStr) — \(issue.issue)"
            }
            text = "\(issues.count) element(s) highlighted (red=missing label, orange=generic, yellow=duplicate):\n"
                + lines.joined(separator: "\n")
        }

        return try ToolResult(
            content: text,
            structuredContent: assistantDiagnosticFields(Value(report), unstable: observation.token != after.token),
            image: observation.token == after.token
                ? annotated.map { ToolImageContent(data: $0, mimeType: ImageFormat.png.mimeType) } : nil
        )
    }

    private func assistantDiagnosticFields(_ payload: Value, unstable: Bool = false) -> Value {
        var fields = payload.objectValue ?? [:]
        fields["executionStatus"] = .string("succeeded")
        fields["verdict"] = .string("notAssessed")
        fields["cleanupStatus"] = .string("notRequired")
        fields["limitations"] =
            .array([.string("Naming/testability heuristics only; no accessibility conformance verdict.")])
        fields["coverage"] = .object([
            "requested": .array([.string("accessibility.semanticAssessment")]), "evaluated": .array([]),
            "notEvaluated": .object(["accessibility.semanticAssessment": .string(unstable
                    ? "Screen changed during screenshot capture; annotation withheld."
                    : "Requires native semantics or authored screen-reader assertions.")]),
            "truncated": .bool(false)
        ])
        return .object(fields)
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
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func executeTakeScreenshot(
        driver: any PlatformDriver,
        arguments: [String: String]
    ) async throws -> ToolResult {
        let requestedFormat = ImageFormat(parsing: arguments["format"])
        let settleTimeout = min(
            arguments["settle_timeout_ms"].flatMap(Int.init) ?? Self.defaultScreenshotSettleMilliseconds,
            10000
        )
        // Image tokens scale with pixel area, so the default is one image pixel per point (iOS) or
        // density-independent pixel (Android): a 3x iPhone capture drops from 1206x2622 to 402x874,
        // a ninth of the pixels, and image coordinates then equal gesture points. `scale` (a
        // fraction of native pixels) overrides it; scale=1 keeps native pixels.
        let explicitScale = arguments["scale"].flatMap(Double.init)
        let options = ScreenshotRequestOptions(
            format: requestedFormat,
            scale: explicitScale.flatMap { $0 < 1 ? $0 : nil },
            pointResolution: explicitScale == nil
        )
        let capture = try await captureSettledScreenshot(
            driver: driver,
            options: options,
            timeoutMilliseconds: settleTimeout
        )
        let screenshot = capture.screenshot
        // Trust the format the driver actually produced — some drivers ignore the
        // requested format (e.g. Android always returns PNG), so labeling by the
        // request would hand clients a wrong MIME type.
        let actualFormat = screenshot.format
        let originalData = Data(screenshot.bytes)

        // A device that scaled at the source reports it; otherwise (an older companion, a host
        // capture) the same target is applied here.
        let hostScale: Double? = if screenshot.appliedScale != nil {
            nil
        } else if let explicitScale {
            explicitScale
        } else {
            (screenshot.density ?? screenshot.geometry?.scale).flatMap { $0 > 1 ? 1 / $0 : nil }
        }
        let scaledData = ScreenshotScaler.scaled(originalData, by: hostScale, format: actualFormat)
        let data = scaledData ?? originalData
        let imageScale = screenshot.appliedScale ?? (scaledData == nil ? 1 : hostScale ?? 1)
        let scalingStatus = screenshot.appliedScale != nil ? "applied_on_device"
            : ScreenshotScaler.scalingStatus(requested: hostScale, scaled: scaledData)

        var fields: [String: Value] = [
            "byte_count": .int(data.count),
            "format": .string(actualFormat.rawValue),
            "scaling_status": .string(scalingStatus),
            "image_scale": .double(imageScale)
        ]
        if data.count != originalData.count {
            fields["original_byte_count"] = .int(originalData.count)
        }
        let quality = ScreenshotQuality.assess(originalData)
        fields["capture_analysis"] = .string(quality.reason)
        if let suspect = quality.suspect {
            fields["capture_suspect"] = .bool(suspect)
        }
        let capturedDeviceState = await deviceObservation(driver: driver, geometry: screenshot.geometry)
        fields.merge(capturedDeviceState, uniquingKeysWith: { _, observed in observed })
        let qualityNote = quality.suspect == true
            ? " — capture_suspect: \(quality.reason); inspect device state before interpreting app content" : ""
        var settleNote = ""
        if let settled = capture.settled {
            fields["settled"] = .bool(settled)
            fields["settle_frames"] = .int(capture.frames)
            if !settled {
                settleNote = " — warning: screen was still changing after \(settleTimeout)ms;"
                    + " image may show a transition"
            }
        }

        // A locked/off screen otherwise looks exactly like the app rendering black — surface it
        // so an agent doesn't start debugging the app for what is actually a device state.
        var screenStateNote = ""
        if let screenState = fields["screen_state"]?.stringValue, screenState != "on" {
            screenStateNote = " — warning: screen is \(screenState), image may not reflect app content"
        }

        // The image is in pixels and gestures take points. Reporting both, and the factor between
        // them, is what stops a position read off this image from being passed straight to `tap`
        // — which lands off-screen and still reports success.
        var geometryNote = ""
        var scaleAuditNote = ""
        if let viewport = fields["viewport"]?.objectValue,
           let screenScale = viewport["scale"]?.doubleValue, screenScale > 0,
           let widthPixels = viewport["width_pixels"]?.doubleValue,
           let heightPixels = viewport["height_pixels"]?.doubleValue,
           let widthPoints = viewport["width_points"]?.doubleValue,
           let heightPoints = viewport["height_points"]?.doubleValue {
            var imageWidth = (widthPixels * imageScale).rounded()
            var imageHeight = (heightPixels * imageScale).rounded()
            var imagePixelsPerPoint = screenScale * imageScale
            let audit = ScreenshotScaler.audit(
                actual: ScreenshotScaler.dimensions(data),
                nominalWidth: imageWidth,
                nominalHeight: imageHeight,
                widthPoints: widthPoints
            )
            fields["scale_audit"] = .string(audit.status.rawValue)
            if audit.status == .mismatch, let actual = ScreenshotScaler.dimensions(data),
               let measured = audit.measuredPixelsPerPoint {
                imageWidth = Double(actual.width)
                imageHeight = Double(actual.height)
                imagePixelsPerPoint = measured
                scaleAuditNote = " — warning: image size differs from the reported scale; using the measured"
                    + " \(measured.formatted()) pixels per point"
            }
            fields["width_pixels"] = .double(imageWidth)
            fields["height_pixels"] = .double(imageHeight)
            fields["width_points"] = .double(widthPoints)
            fields["height_points"] = .double(heightPoints)
            fields["scale"] = .double(imagePixelsPerPoint)
            geometryNote = " — image is \(geometryNumber(imageWidth))x\(geometryNumber(imageHeight))px;"
                + " gestures take points (\(geometryNumber(widthPoints))"
                + "x\(geometryNumber(heightPoints))),"
                + " so divide image coordinates by \(imagePixelsPerPoint.formatted())"
            if imageScale == 1 {
                geometryNote += " or pass unit=pixels"
            } else {
                geometryNote += "; unit=pixels expects native screenshot pixels"
            }
        }

        var savedNote = ""
        fields.merge(Self.screenshotDimensionFields(data), uniquingKeysWith: { _, actual in actual })
        let returnImage = boolArgument(arguments["return_image"]) == true
        // Saved by default: the path costs a few tokens and the client reads the file only when it
        // needs pixels, instead of carrying an image through every later turn.
        let output = arguments["output"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (returnImage ? nil : Self.scratchScreenshotPath(
                sessionID: arguments["session_id"],
                format: actualFormat
            ))
        if let output {
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
                + "\(savedNote)\(formatNote)\(geometryNote)\(scaleAuditNote)"
                + "\(screenStateNote)\(settleNote)\(qualityNote)",
            structuredContent: .object(fields),
            image: returnImage ? ToolImageContent(data: data, mimeType: actualFormat.mimeType) : nil
        )
    }

    /// `$TMPDIR/amoo-screenshots/<session>/<time>.<ext>` for a capture saved without `output`.
    static func scratchScreenshotPath(sessionID: String?, format: ImageFormat) -> String? {
        let session = sessionID.flatMap { UUID(uuidString: $0)?.uuidString } ?? "adhoc"
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "amoo-screenshots/\(session)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        let stamp = Date().ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "")
        let suffix = UUID().uuidString.prefix(6)
        let ext = format == .jpeg ? "jpg" : "png"
        return directory.appending(path: "\(stamp)-\(suffix).\(ext)").path
    }

    static let defaultScreenshotSettleMilliseconds = 1500

    private struct SettledCapture {
        let screenshot: ScreenshotData
        /// nil when settling was disabled.
        let settled: Bool?
        let frames: Int
    }

    /// Small probe frames used only to detect that the screen stopped changing.
    static func settleProbe(_ options: ScreenshotRequestOptions) -> ScreenshotRequestOptions {
        ScreenshotRequestOptions(format: options.format, scale: 0.25, quality: options.quality)
    }

    /// Captures small probe frames until two consecutive ones are byte-identical or the timeout
    /// passes, then the requested capture. Identical encoded frames mean identical pixels, so this
    /// catches sheet dismissals and push transitions that a hierarchy snapshot can report as done,
    /// while each probe moves a sixteenth of a native frame. A device that cannot scale returns
    /// native probes; then the settled probe is the result.
    private func captureSettledScreenshot(
        driver: any PlatformDriver,
        options: ScreenshotRequestOptions,
        timeoutMilliseconds: Int
    ) async throws -> SettledCapture {
        guard timeoutMilliseconds > 0 else {
            return try await SettledCapture(screenshot: driver.takeScreenshot(options), settled: nil, frames: 1)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeoutMilliseconds)
        var previous = try await driver.takeScreenshot(Self.settleProbe(options))
        var frames = 1
        var settled = false
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(120))
            guard clock.now < deadline else { break }
            let next: ScreenshotData
            do {
                next = try await OperationDeadline.read(until: deadline) {
                    try await driver.takeScreenshot(Self.settleProbe(options))
                }
            } catch is OperationDeadline.DeadlineExceeded { break }
            frames += 1
            if next.bytes == previous.bytes {
                previous = next
                settled = true
                break
            }
            previous = next
        }
        // A device that ignored the probe's scale cannot scale the final capture either; the host
        // scales the settled frame instead of capturing it again.
        if previous.appliedScale == nil {
            return SettledCapture(screenshot: previous, settled: settled, frames: frames)
        }
        let final = try await driver.takeScreenshot(options)
        return SettledCapture(screenshot: final, settled: settled, frames: frames + 1)
    }
}
