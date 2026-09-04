import Foundation

/// `CDPChannelFactory` over `URLSession` — HTTP GET for `/json`, a `URLSessionWebSocketTask` for
/// the debugger socket. This is the real transport for Android (and the iwdp iOS bridge).
public struct URLSessionCDPChannelFactory: CDPChannelFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func targetsJSON(baseURL: URL) async throws -> Data {
        let url = baseURL.appendingPathComponent("json")
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                throw WebInspectorError.transportUnavailable("GET \(url) returned a non-2xx response")
            }
            return data
        } catch let error as WebInspectorError {
            throw error
        } catch {
            throw WebInspectorError.transportUnavailable("GET \(url) failed: \(error.localizedDescription)")
        }
    }

    public func openChannel(webSocketURL: URL) async throws -> any CDPChannel {
        let task = session.webSocketTask(with: webSocketURL)
        task.resume()
        return URLSessionCDPChannel(task: task)
    }
}

private final class URLSessionCDPChannel: CDPChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case let .data(data):
            return data
        case let .string(string):
            return Data(string.utf8)
        @unknown default:
            throw WebInspectorError.protocolError("unknown WebSocket frame type")
        }
    }

    func close() async {
        task.cancel(with: .goingAway, reason: nil)
    }
}
