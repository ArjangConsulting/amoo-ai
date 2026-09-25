import AmooCore
import Foundation
import MCP
import WebInspector

extension DriverToolExecutor {
    // MARK: - WebView / DOM introspection

    func executeWebViewEval(arguments: [String: String]) async -> ToolResult {
        guard let expression = arguments["expression"], !expression.isEmpty else {
            return .error("Missing required argument: expression")
        }
        let bundleID = arguments["bundle_id"]
        do {
            let client = try await webInspectorClient(arguments: arguments, bundleID: bundleID)
            let request = WebViewEvalRequest(
                expression: expression,
                bundleID: bundleID,
                allFrames: boolArgument(arguments["all_frames"]) ?? false,
                timeoutMilliseconds: arguments["timeout_ms"].flatMap(Int.init) ?? 5000
            )
            let evaluated = await Result { try await client.evaluate(request) }
            await client.close()
            let result = try evaluated.get()
            var fields: [String: Value] = [
                "value": .string(result.jsonValue),
                "webview_index": .int(result.webViewIndex),
                "is_exception": .bool(result.isException)
            ]
            if let frameURL = result.frameURL {
                fields["frame_url"] = .string(frameURL)
            }
            let label = result.isException ? "threw" : "="
            return .success(
                "webview_eval [\(result.webViewIndex)] \(label) \(result.jsonValue)",
                structuredContent: .object(fields)
            )
        } catch {
            return .error("webview_eval failed: \(webInspectorMessage(error))")
        }
    }

    func executeWebViewDom(arguments: [String: String]) async -> ToolResult {
        let bundleID = arguments["bundle_id"]
        let mode: WebViewDomRequest.Mode = arguments["mode"]?.lowercased() == "a11y" ? .a11y : .html
        do {
            let client = try await webInspectorClient(arguments: arguments, bundleID: bundleID)
            let request = WebViewDomRequest(
                bundleID: bundleID,
                mode: mode,
                maxBytes: arguments["max_bytes"].flatMap(Int.init)
            )
            let fetched = await Result { try await client.dom(request) }
            await client.close()
            let documents = try fetched.get()
            let rows = documents.map { document -> Value in
                var fields: [String: Value] = [
                    "webview_index": .int(document.webViewIndex),
                    "content": .string(document.content)
                ]
                if let frameURL = document.frameURL {
                    fields["frame_url"] = .string(frameURL)
                }
                return .object(fields)
            }
            let summary = documents
                .map { "[\($0.webViewIndex)] \($0.content.count) chars" }
                .joined(separator: ", ")
            return .success(
                "webview_dom: \(documents.count) document(s) — \(summary)",
                structuredContent: .object(["documents": .array(rows)])
            )
        } catch {
            return .error("webview_dom failed: \(webInspectorMessage(error))")
        }
    }

    /// Resolves the client for the device this call targets: the session's device when a
    /// `session_id` is given, otherwise the executor's default driver (`--device`). The explicit
    /// `platform` argument wins; without one, the device's own platform is used, so an Android
    /// MCP server no longer defaults WebView calls to iOS.
    private func webInspectorClient(
        arguments: [String: String],
        bundleID: String?
    ) async throws -> any WebInspectorClient {
        let driver = try await resolveDriver(arguments: arguments)
        let device = try? await driver.deviceInfo()
        let platform = arguments["platform"].flatMap { WebInspectorPlatform(rawValue: $0.lowercased()) }
            ?? device.flatMap { WebInspectorPlatform(rawValue: $0.platform.rawValue) }
            ?? defaultPlatform.flatMap { WebInspectorPlatform(rawValue: $0.rawValue) }
            ?? .ios
        return try await webInspector.client(platform: platform, bundleID: bundleID, deviceID: device?.id)
    }

    private func webInspectorMessage(_ error: any Error) -> String {
        (error as? WebInspectorError)?.description ?? "\(error)"
    }
}
