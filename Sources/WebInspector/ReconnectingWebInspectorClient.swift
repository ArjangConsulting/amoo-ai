import Foundation

/// Wraps a `WebInspectorClient` whose transport can drop out from under it. iOS's `webinspectord`
/// exits roughly every 10 s when idle, so a connection (or a handshake) can die between amoo's
/// calls. On `transportUnavailable` this reconnects and retries within the call's own
/// `timeout_ms`, and reports the real elapsed budget if it gives up. Non-transport errors — a
/// page exception, a genuine evaluation timeout, "no inspectable WebView" — pass through
/// untouched, so an expression is only ever re-sent when its connection died.
public actor ReconnectingWebInspectorClient: WebInspectorClient {
    public typealias Connect = @Sendable () async throws -> any WebInspectorClient

    private let connect: Connect
    private var current: (any WebInspectorClient)?
    private let retryDelay: Duration
    private let maxAttempts: Int
    private let domTimeout: Duration

    public init(
        initial: (any WebInspectorClient)? = nil,
        retryDelay: Duration = .milliseconds(300),
        maxAttempts: Int = 6,
        domTimeout: Duration = .seconds(10),
        connect: @escaping Connect
    ) {
        current = initial
        self.connect = connect
        self.retryDelay = retryDelay
        self.maxAttempts = maxAttempts
        self.domTimeout = domTimeout
    }

    public func evaluate(_ request: WebViewEvalRequest) async throws -> WebViewEvalResult {
        let started = ContinuousClock.now
        let deadline = started + .milliseconds(request.timeoutMilliseconds)
        return try await withReconnect(started: started, deadline: deadline) { client in
            var attempt = request
            attempt.timeoutMilliseconds = max(1, (deadline - ContinuousClock.now).milliseconds)
            return try await client.evaluate(attempt)
        }
    }

    public func dom(_ request: WebViewDomRequest) async throws -> [WebViewDocument] {
        let started = ContinuousClock.now
        return try await withReconnect(started: started, deadline: started + domTimeout) { client in
            try await client.dom(request)
        }
    }

    public func close() async {
        let client = current
        current = nil
        await client?.close()
    }

    private func withReconnect<T: Sendable>(
        started: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant,
        _ operation: (any WebInspectorClient) async throws -> T
    ) async throws -> T {
        var attempts = 0
        var lastReason = ""
        while true {
            attempts += 1
            do {
                let client: any WebInspectorClient
                if let current {
                    client = current
                } else {
                    client = try await connect()
                    current = client
                }
                return try await operation(client)
            } catch WebInspectorError.transportUnavailable(let reason) {
                lastReason = reason
                await close()
            }
            guard attempts < maxAttempts, ContinuousClock.now + retryDelay < deadline else {
                let elapsed = (ContinuousClock.now - started).milliseconds
                throw WebInspectorError.transportUnavailable(
                    "\(lastReason) (gave up after \(attempts) attempt(s) in \(elapsed)ms)"
                )
            }
            try await Task.sleep(for: retryDelay)
        }
    }
}
