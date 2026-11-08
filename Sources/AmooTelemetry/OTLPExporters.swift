import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import OTLP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Appends OTLP/JSON lines (one `ExportTraceServiceRequest` per line) to a daily file — the
/// OpenTelemetry "OTLP File" format, readable by `amoo usage report` and by the Collector's
/// `otlpjsonfile` receiver. Several amoo processes may append to the same file.
public actor OTLPFileExporter: SpanExporter {
    nonisolated public let name = "otlp-file"
    public let directory: URL
    private let retentionDays: Int
    private var pruned = false
    /// Keeps each appended line (one atomic `write`) a bounded size.
    static let spansPerLine = 64

    public init(directory: URL, retentionDays: Int = 14) {
        self.directory = directory
        self.retentionDays = retentionDays
    }

    /// `traces-YYYY-MM-DD.jsonl`, by UTC day.
    public static func fileName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "traces-%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func export(_ spans: [SpanRecord], resource: TelemetryResource) async throws {
        guard !spans.isEmpty else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        if !pruned {
            pruned = true
            prune()
        }
        let path = directory.appending(path: Self.fileName(for: Date())).path
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        defer { close(descriptor) }
        var start = 0
        while start < spans.count {
            let chunk = Array(spans[start ..< min(start + Self.spansPerLine, spans.count)])
            start += Self.spansPerLine
            var line = try OTLPEncoding.json(OTLPEncoding.request(chunk, resource: resource))
            line.append(UInt8(ascii: "\n"))
            let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard written == line.count else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        }
    }

    public func shutdown() async {}

    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        for file in files where file.lastPathComponent.hasPrefix("traces-") && file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// Writes OTLP/JSON lines to standard error (`OTEL_TRACES_EXPORTER=console`).
public struct OTLPConsoleExporter: SpanExporter {
    public let name = "console"

    public init() {}

    public func export(_ spans: [SpanRecord], resource: TelemetryResource) async throws {
        var line = try OTLPEncoding.json(OTLPEncoding.request(spans, resource: resource))
        line.append(UInt8(ascii: "\n"))
        FileHandle.standardError.write(line)
    }

    public func shutdown() async {}
}

/// OTLP/HTTP exporter in `http/protobuf` (default per the specification) or `http/json`.
public struct OTLPHTTPExporter: SpanExporter {
    public enum Encoding: Sendable {
        case protobuf
        case json
    }

    public let name = "otlp-http"
    let endpoint: URL
    let encoding: Encoding
    let headers: [String: String]
    let timeout: Duration
    private let session: URLSession

    public init(endpoint: URL, encoding: Encoding, headers: [String: String], timeout: Duration) {
        self.endpoint = endpoint
        self.encoding = encoding
        self.headers = headers
        self.timeout = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Double(timeout.components.seconds) + 1
        session = URLSession(configuration: configuration)
    }

    public func export(_ spans: [SpanRecord], resource: TelemetryResource) async throws {
        let message = OTLPEncoding.request(spans, resource: resource)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        switch encoding {
        case .protobuf:
            request.httpBody = try message.serializedBytes()
            request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        case .json:
            request.httpBody = try OTLPEncoding.json(message)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Retry once on the statuses the specification marks retryable.
        for attempt in 0 ..< 2 {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200 ..< 300).contains(status) {
                return
            }
            guard [429, 502, 503, 504].contains(status), attempt == 0 else {
                throw OTLPExportError.httpStatus(status)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    public func shutdown() async {
        session.finishTasksAndInvalidate()
    }
}

public enum OTLPExportError: Error, CustomStringConvertible {
    case httpStatus(Int)

    public var description: String {
        switch self {
        case let .httpStatus(status): "OTLP/HTTP collector returned status \(status)"
        }
    }
}

/// OTLP/gRPC exporter over the same grpc-swift transport the companions use.
public actor OTLPGRPCExporter: SpanExporter {
    nonisolated public let name = "otlp-grpc"
    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    private let headers: [String: String]
    private let timeout: Duration
    private var connection: Task<Void, Never>?

    public init(host: String, port: Int, secure: Bool, headers: [String: String], timeout: Duration) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: port),
            transportSecurity: secure ? .tls : .plaintext
        )
        client = GRPCClient(transport: transport)
        self.headers = headers
        self.timeout = timeout
    }

    public func export(_ spans: [SpanRecord], resource: TelemetryResource) async throws {
        if connection == nil {
            let client = client
            connection = Task { try? await client.runConnections() }
        }
        var metadata = Metadata()
        for (key, value) in headers {
            metadata.addString(value, forKey: key.lowercased())
        }
        var options = CallOptions.defaults
        options.timeout = timeout
        let service = Opentelemetry_Proto_Collector_Trace_V1_TraceService.Client(wrapping: client)
        _ = try await service.export(
            OTLPEncoding.request(spans, resource: resource), metadata: metadata, options: options
        )
    }

    public func shutdown() async {
        client.beginGracefulShutdown()
        connection?.cancel()
        _ = await connection?.result
    }
}
