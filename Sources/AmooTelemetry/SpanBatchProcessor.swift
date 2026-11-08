import AmooLogging
import Foundation
import Synchronization

/// The OpenTelemetry resource and instrumentation scope attached to every exported batch.
public struct TelemetryResource: Sendable {
    public let attributes: [String: TelemetryValue]
    public let scopeName: String
    public let scopeVersion: String

    public init(attributes: [String: TelemetryValue], scopeName: String = "amoo", scopeVersion: String) {
        self.attributes = attributes
        self.scopeName = scopeName
        self.scopeVersion = scopeVersion
    }
}

/// Receives finished spans in batches. Implementations must tolerate being called repeatedly
/// and must not throw for transient failures they can retry themselves.
public protocol SpanExporter: Sendable {
    /// Human-readable exporter name for diagnostics, e.g. `otlp-file`.
    var name: String { get }
    func export(_ spans: [SpanRecord], resource: TelemetryResource) async throws
    func shutdown() async
}

/// Batches finished spans and exports them off the caller's path (OpenTelemetry's
/// BatchSpanProcessor). `enqueue` is synchronous and never blocks on I/O.
public final class SpanBatchProcessor: Sendable {
    public struct Limits: Sendable {
        public var scheduleDelay: Duration = .seconds(2)
        public var maxQueueSize = 2048
        public var maxExportBatchSize = 512

        public init() {}
    }

    private struct State {
        var queue: [SpanRecord] = []
        var dropped = 0
        var stopped = false
    }

    /// `Mutex` is noncopyable; a class reference lets the background tasks share it.
    private final class SharedState: Sendable {
        let mutex = Mutex(State())
    }

    private let shared = SharedState()
    private let pipeline: ExportPipeline
    private let limits: Limits
    private let wake: AsyncStream<Void>.Continuation
    private let loop: Task<Void, Never>
    private let timer: Task<Void, Never>

    public init(exporters: [any SpanExporter], resource: TelemetryResource, limits: Limits = Limits()) {
        let pipeline = ExportPipeline(exporters: exporters, resource: resource)
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.pipeline = pipeline
        self.limits = limits
        wake = continuation
        let shared = shared
        let batchSize = limits.maxExportBatchSize
        loop = Task.detached(priority: .utility) {
            for await _ in stream {
                await Self.drain(shared: shared, pipeline: pipeline, batchSize: batchSize)
            }
        }
        let delay = limits.scheduleDelay
        timer = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                continuation.yield()
            }
        }
    }

    deinit {
        timer.cancel()
        wake.finish()
    }

    /// Adds a finished span; drops it (and counts the drop) when the queue is full.
    public func enqueue(_ record: SpanRecord) {
        let shouldWake = shared.mutex.withLock { current -> Bool in
            guard !current.stopped else { return false }
            guard current.queue.count < limits.maxQueueSize else {
                current.dropped += 1
                return false
            }
            current.queue.append(record)
            return current.queue.count >= limits.maxExportBatchSize
        }
        if shouldWake {
            wake.yield()
        }
    }

    /// Asks the background loop to export what is queued without waiting for it.
    public func requestFlush() {
        wake.yield()
    }

    /// Exports everything queued so far and waits for the exporters to finish.
    public func flush() async {
        await Self.drain(shared: shared, pipeline: pipeline, batchSize: limits.maxExportBatchSize)
    }

    /// Flushes, stops accepting spans and shuts the exporters down. Idempotent.
    public func shutdown() async {
        await flush()
        let first = shared.mutex.withLock { current -> Bool in
            defer { current.stopped = true }
            return !current.stopped
        }
        guard first else { return }
        timer.cancel()
        wake.finish()
        await loop.value
        await pipeline.shutdown()
    }

    /// Spans dropped because the queue was full.
    public var droppedSpans: Int {
        shared.mutex.withLock { $0.dropped }
    }

    private static func drain(shared: SharedState, pipeline: ExportPipeline, batchSize: Int) async {
        while true {
            let batch = shared.mutex.withLock { current -> [SpanRecord] in
                let count = min(batchSize, current.queue.count)
                let batch = Array(current.queue.prefix(count))
                current.queue.removeFirst(count)
                return batch
            }
            guard !batch.isEmpty else { return }
            await pipeline.export(batch)
        }
    }
}

/// Serializes exports so exporters never see concurrent calls.
private actor ExportPipeline {
    private let exporters: [any SpanExporter]
    private let resource: TelemetryResource
    private var reportedFailures: Set<String> = []
    private let logger = AmooLogger.forType(ExportPipeline.self)

    init(exporters: [any SpanExporter], resource: TelemetryResource) {
        self.exporters = exporters
        self.resource = resource
    }

    func export(_ batch: [SpanRecord]) async {
        for exporter in exporters {
            do {
                try await exporter.export(batch, resource: resource)
            } catch {
                // Telemetry must never fail the operation it observes; report each exporter once.
                if reportedFailures.insert(exporter.name).inserted {
                    logger.error(
                        "Span export failed",
                        error: error,
                        context: "feature=telemetry action=export exporter=\(exporter.name) spans=\(batch.count)"
                    )
                }
            }
        }
    }

    func shutdown() async {
        for exporter in exporters {
            await exporter.shutdown()
        }
    }
}
