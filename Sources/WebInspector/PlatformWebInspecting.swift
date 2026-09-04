import Foundation

public struct WebInspectorShellResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a shell command — matches `ProcessRunner.ProcessRunner` without this target depending on it.
public protocol WebInspectorShell: Sendable {
    func run(_ arguments: [String]) async throws -> WebInspectorShellResult
}

/// Wires each platform to a CDP endpoint:
///  - **Android**: `adb` finds the `webview_devtools_remote_<pid>` abstract socket, forwards a
///    local TCP port to it, and the CDP client talks to `http://127.0.0.1:<port>`.
///  - **iOS**: needs the WebKit Remote Inspector bridge. Not wired up yet — this throws with a
///    pointer to `docs/webview-introspection.md`. Set `AMOO_IOS_WEBINSPECTOR_URL` to a
///    CDP-compatible endpoint (e.g. a running `ios-webkit-debug-proxy`) to opt in early.
public struct PlatformWebInspecting: WebInspecting {
    private let shell: any WebInspectorShell
    private let factory: any CDPChannelFactory
    private let environment: [String: String]

    public init(
        shell: any WebInspectorShell,
        factory: any CDPChannelFactory = URLSessionCDPChannelFactory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.shell = shell
        self.factory = factory
        self.environment = environment
    }

    public func client(
        platform: WebInspectorPlatform,
        bundleID: String?
    ) async throws -> any WebInspectorClient {
        switch platform {
        case .android:
            let baseURL = try await androidBaseURL()
            return CDPWebInspectorClient(baseURL: baseURL, factory: factory, bundleID: bundleID)
        case .ios:
            guard let raw = environment["AMOO_IOS_WEBINSPECTOR_URL"], let url = URL(string: raw) else {
                throw WebInspectorError.iosTransportNotImplemented
            }
            return CDPWebInspectorClient(baseURL: url, factory: factory, bundleID: bundleID)
        }
    }

    // MARK: - Android

    private func androidBaseURL() async throws -> URL {
        let sockets = try await run(["adb", "shell", "cat", "/proc/net/unix"])
        guard let name = Self.firstDevtoolsSocket(in: sockets) else {
            throw WebInspectorError.noInspectableWebViews(bundleID: nil)
        }
        let forward = try await run(["adb", "forward", "tcp:0", "localabstract:\(name)"])
        guard
            let port = Int(forward.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0,
            let url = URL(string: "http://127.0.0.1:\(port)")
        else {
            throw WebInspectorError.transportUnavailable("`adb forward` did not return a usable local port")
        }
        return url
    }

    static func firstDevtoolsSocket(in procNetUnix: String) -> String? {
        for line in procNetUnix.split(whereSeparator: \.isNewline) {
            guard let at = line.range(of: "@webview_devtools_remote_") else { continue }
            let name = line[at.lowerBound...].dropFirst() // drop the leading '@'
            return String(name).split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return nil
    }

    private func run(_ arguments: [String]) async throws -> String {
        let result = try await shell.run(arguments)
        guard result.exitCode == 0 else {
            throw WebInspectorError.transportUnavailable(
                "\(arguments.joined(separator: " ")) failed: \(result.stderr)"
            )
        }
        return result.stdout
    }
}
