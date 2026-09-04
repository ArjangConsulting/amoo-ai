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
        let platform = webInspectorPlatform(arguments)
        let bundleID = arguments["bundle_id"]
        do {
            let client = try await webInspector.client(platform: platform, bundleID: bundleID)
            let result = try await client.evaluate(
                WebViewEvalRequest(
                    expression: expression,
                    bundleID: bundleID,
                    allFrames: boolArgument(arguments["all_frames"]) ?? false,
                    timeoutMilliseconds: arguments["timeout_ms"].flatMap(Int.init) ?? 5000
                )
            )
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
        let platform = webInspectorPlatform(arguments)
        let bundleID = arguments["bundle_id"]
        let mode: WebViewDomRequest.Mode = arguments["mode"]?.lowercased() == "a11y" ? .a11y : .html
        do {
            let client = try await webInspector.client(platform: platform, bundleID: bundleID)
            let documents = try await client.dom(
                WebViewDomRequest(
                    bundleID: bundleID,
                    mode: mode,
                    maxBytes: arguments["max_bytes"].flatMap(Int.init)
                )
            )
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

    private func webInspectorPlatform(_ arguments: [String: String]) -> WebInspectorPlatform {
        WebInspectorPlatform(rawValue: (arguments["platform"] ?? "ios").lowercased()) ?? .ios
    }

    private func webInspectorMessage(_ error: any Error) -> String {
        (error as? WebInspectorError)?.description ?? "\(error)"
    }
}
