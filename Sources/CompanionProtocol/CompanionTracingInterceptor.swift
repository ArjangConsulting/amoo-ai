import AmooTelemetry
import Foundation
import GRPCCore
import Tracing

/// Wraps every companion RPC in an OpenTelemetry client span (RPC semantic conventions),
/// injects W3C `traceparent` into the request metadata, and records the companion's own
/// handling time from the `amoo-server-ms` response metadata, so a span shows how much of a call
/// was device work versus transport.
struct CompanionTracingInterceptor: ClientInterceptor {
    static let serverTimingKey = "amoo-server-ms"

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        let service = context.descriptor.service.fullyQualifiedService
        let method = context.descriptor.method
        let span = InstrumentationSystem.tracer.startSpan("\(service)/\(method)", ofKind: .client)
        span.attributes[TelemetryAttribute.rpcSystem] = "grpc"
        span.attributes[TelemetryAttribute.rpcService] = service
        span.attributes[TelemetryAttribute.rpcMethod] = method
        var request = request
        InstrumentationSystem.instrument.inject(span.context, into: &request.metadata, using: MetadataCarrier())
        let response: StreamingClientResponse<Output>
        do {
            response = try await next(request, context)
        } catch {
            Self.finish(span, error: error)
            throw error
        }
        switch response.accepted {
        case let .failure(error):
            Self.finish(span, error: error)
            return response
        case var .success(contents):
            Self.recordServerTiming(contents.metadata, on: span)
            contents.bodyParts = RPCAsyncSequence(wrapping: SpanEndingSequence(base: contents.bodyParts, span: span))
            return StreamingClientResponse(accepted: .success(contents))
        }
    }

    static func recordServerTiming(_ metadata: Metadata, on span: any Tracing.Span) {
        guard let raw = metadata[stringValues: serverTimingKey].first(where: { _ in true }),
              let milliseconds = Double(raw) else { return }
        span.attributes[TelemetryAttribute.companionServerMilliseconds] = milliseconds
    }

    static func finish(_ span: any Tracing.Span, error: any Error) {
        let code = (error as? RPCError)?.code ?? .unknown
        span.attributes[TelemetryAttribute.rpcGRPCStatusCode] = Int(code.rawValue)
        span.attributes[TelemetryAttribute.errorType] = String(describing: code)
        span.setStatus(SpanStatus(code: .error, message: String(describing: code)))
        span.end()
    }
}

private struct MetadataCarrier: Injector {
    func inject(_ value: String, forKey key: String, into carrier: inout Metadata) {
        carrier.replaceOrAddString(value, forKey: key)
    }
}

/// Ends the RPC span when the response stream finishes, reading the status and any trailing
/// server timing on the way.
private struct SpanEndingSequence<Output: Sendable>: AsyncSequence, Sendable {
    typealias Element = StreamingClientResponse<Output>.Contents.BodyPart

    let base: RPCAsyncSequence<Element, any Error>
    let span: any Tracing.Span

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: RPCAsyncSequence<Element, any Error>.AsyncIterator
        let span: any Tracing.Span

        mutating func next() async throws -> Element? {
            do {
                guard let part = try await base.next() else {
                    if span.isRecording {
                        span.attributes[TelemetryAttribute.rpcGRPCStatusCode] = 0
                        span.end()
                    }
                    return nil
                }
                if case let .trailingMetadata(trailers) = part {
                    CompanionTracingInterceptor.recordServerTiming(trailers, on: span)
                }
                return part
            } catch {
                CompanionTracingInterceptor.finish(span, error: error)
                throw error
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), span: span)
    }
}
