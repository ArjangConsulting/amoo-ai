import Foundation
import GRPCCore

/// Reports how long the companion spent on each RPC in the `amoo-server-ms` trailer, so the host's
/// OpenTelemetry RPC span can separate on-device work (XCUITest queries, gestures, captures) from
/// transport and host overhead.
struct ServerTimingInterceptor: ServerInterceptor {
    static let key = "amoo-server-ms"

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (StreamingServerRequest<Input>, ServerContext) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        let start = ContinuousClock.now
        var response = try await next(request, context)
        guard case var .success(contents) = response.accepted else { return response }
        let producer = contents.producer
        contents.producer = { writer in
            var trailers = try await producer(writer)
            trailers.replaceOrAddString(Self.milliseconds(since: start), forKey: Self.key)
            return trailers
        }
        response.accepted = .success(contents)
        return response
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        return String(format: "%.1f", milliseconds)
    }
}
