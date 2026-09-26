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
        bundleID: String?,
        deviceID: String?
    ) async throws -> any WebInspectorClient {
        switch platform {
        case .android:
            return try await androidClient(bundleID: bundleID, serial: deviceID)
        case .ios:
            guard let raw = environment["AMOO_IOS_WEBINSPECTOR_URL"], let url = URL(string: raw) else {
                throw WebInspectorError.iosTransportNotImplemented
            }
            return CDPWebInspectorClient(baseURL: url, factory: factory, bundleID: bundleID)
        }
    }

    // MARK: - Android

    /// Finds the app's `webview_devtools_remote_<pid>` socket, forwards a fresh local port to it,
    /// and returns a client that removes that forward on `close()`. Every `adb` call is scoped to
    /// `serial`. Forwards left by earlier (crashed) calls whose WebView process has since died are
    /// swept first, so they no longer accumulate.
    private func androidClient(bundleID: String?, serial: String?) async throws -> any WebInspectorClient {
        let adb = Self.adbPrefix(serial: serial)
        // Check the app first: a crashed app has no socket either, and "enable web debugging"
        // would send the caller after the wrong problem.
        var pids: String?
        if let bundleID {
            let result = try await shell.run(adb + ["shell", "pidof", bundleID])
            guard result.exitCode == 0, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WebInspectorError.appNotRunning(bundleID: bundleID)
            }
            pids = result.stdout
        }
        let sockets = try await Self.devtoolsSockets(in: run(adb + ["shell", "cat", "/proc/net/unix"]))
        let name: String
        if let pids {
            guard let match = Self.socket(forPIDs: pids, in: sockets) else {
                throw WebInspectorError.noInspectableWebViews(bundleID: bundleID)
            }
            name = match
        } else {
            guard let first = sockets.first else { throw WebInspectorError.noInspectableWebViews(bundleID: nil) }
            name = first
        }

        if let serial, let forwards = try? await shell.run(adb + ["forward", "--list"]).stdout {
            for port in Self.staleForwardPorts(in: forwards, serial: serial, liveSockets: sockets) {
                _ = try? await shell.run(adb + ["forward", "--remove", "tcp:\(port)"])
            }
        }

        let forward = try await run(adb + ["forward", "tcp:0", "localabstract:\(name)"])
        guard
            let port = Int(forward.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0,
            let url = URL(string: "http://127.0.0.1:\(port)")
        else {
            throw WebInspectorError.transportUnavailable("`adb forward` did not return a usable local port")
        }
        let shell = shell
        return ForwardedWebInspectorClient(
            inner: CDPWebInspectorClient(baseURL: url, factory: factory, bundleID: bundleID),
            release: { _ = try? await shell.run(adb + ["forward", "--remove", "tcp:\(port)"]) }
        )
    }

    static func adbPrefix(serial: String?) -> [String] {
        guard let serial, !serial.isEmpty, serial != "booted" else { return ["adb"] }
        return ["adb", "-s", serial]
    }

    /// Every `webview_devtools_remote_<pid>` abstract socket name, in `/proc/net/unix` order.
    static func devtoolsSockets(in procNetUnix: String) -> [String] {
        var names: [String] = []
        for line in procNetUnix.split(whereSeparator: \.isNewline) {
            guard let at = line.range(of: "@webview_devtools_remote_") else { continue }
            let rest = line[at.lowerBound...].dropFirst() // drop the leading '@'
            if let name = rest.split(whereSeparator: \.isWhitespace).first.map(String.init),
               !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    static func firstDevtoolsSocket(in procNetUnix: String) -> String? {
        devtoolsSockets(in: procNetUnix).first
    }

    /// The socket owned by one of `pids` (`pidof` output: space-separated).
    static func socket(forPIDs pids: String, in sockets: [String]) -> String? {
        let wanted = Set(pids.split(whereSeparator: \.isWhitespace).map { "webview_devtools_remote_\($0)" })
        return sockets.first(where: wanted.contains)
    }

    /// Local ports of `serial`'s WebView forwards whose target socket no longer exists.
    /// `adb forward --list` lines read `<serial> tcp:<port> localabstract:<name>`.
    static func staleForwardPorts(in forwardList: String, serial: String, liveSockets: [String]) -> [Int] {
        let live = Set(liveSockets)
        return forwardList.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, fields[0] == serial,
                  fields[1].hasPrefix("tcp:"),
                  fields[2].hasPrefix("localabstract:webview_devtools_remote_"),
                  !live.contains(String(fields[2].dropFirst("localabstract:".count)))
            else { return nil }
            return Int(fields[1].dropFirst("tcp:".count))
        }
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

/// A `WebInspectorClient` that owns a transport resource (the Android `adb forward`) and
/// releases it on `close()`.
struct ForwardedWebInspectorClient: WebInspectorClient {
    let inner: any WebInspectorClient
    let release: @Sendable () async -> Void

    func evaluate(_ request: WebViewEvalRequest) async throws -> WebViewEvalResult {
        try await inner.evaluate(request)
    }

    func dom(_ request: WebViewDomRequest) async throws -> [WebViewDocument] {
        try await inner.dom(request)
    }

    func close() async {
        await inner.close()
        await release()
    }
}
