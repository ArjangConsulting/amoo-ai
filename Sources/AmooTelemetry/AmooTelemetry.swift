// swiftlint:disable multiline_arguments
import AmooLogging
import Foundation
import Instrumentation
import Tracing

/// OpenTelemetry configuration resolved from the standard `OTEL_*` environment variables.
///
/// Supported: `OTEL_SDK_DISABLED`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`,
/// `OTEL_TRACES_EXPORTER` (`otlp`, `console`, `none`; comma-separated), `OTEL_EXPORTER_OTLP_ENDPOINT`,
/// `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP[_TRACES]_PROTOCOL` (`grpc`, `http/protobuf`,
/// `http/json`), `OTEL_EXPORTER_OTLP[_TRACES]_HEADERS`, `OTEL_EXPORTER_OTLP[_TRACES]_TIMEOUT`,
/// `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE`.
///
/// Two deliberate defaults differ from the SDK specification: remote export is off unless
/// `OTEL_TRACES_EXPORTER` or an OTLP endpoint is set (no collector is assumed on a developer
/// machine), and amoo always keeps a local OTLP/JSON file unless `AMOO_TELEMETRY_LOCAL=0`.
public struct TelemetryConfiguration: Sendable {
    public enum OTLPProtocol: String, Sendable {
        case grpc
        case httpProtobuf = "http/protobuf"
        case httpJSON = "http/json"
    }

    public var disabled = false
    public var serviceName = "amoo"
    public var serviceVersion = "unknown"
    public var resourceAttributes: [String: String] = [:]
    public var localDirectory: URL?
    public var console = false
    public var otlpEndpoint: URL?
    /// True when the endpoint came from the signal-specific variable (used as-is, no `/v1/traces`).
    public var otlpEndpointIsSignalSpecific = false
    public var otlpProtocol: OTLPProtocol = .httpProtobuf
    public var otlpHeaders: [String: String] = [:]
    public var otlpTimeout: Duration = .seconds(10)
    public var limits = SpanBatchProcessor.Limits()
    /// Parent context inherited from the invoking process (`TRACEPARENT`), e.g. an agent's tool span.
    public var inheritedParent: SpanContext?

    public init() {}

    /// Resolves configuration from `environment`; `localDirectory` is the default local file location.
    public static func fromEnvironment(
        _ environment: [String: String],
        serviceVersion: String,
        localDirectory: URL?
    ) -> Self {
        var config = Self()
        config.serviceVersion = serviceVersion
        config.disabled = environment["OTEL_SDK_DISABLED"]?.lowercased() == "true"
        if let name = environment["OTEL_SERVICE_NAME"], !name.isEmpty {
            config.serviceName = name
        }
        config.resourceAttributes = parsePairs(environment["OTEL_RESOURCE_ATTRIBUTES"])
        if environment["AMOO_TELEMETRY_LOCAL"] != "0" {
            config.localDirectory = environment["AMOO_TELEMETRY_DIR"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? localDirectory
        }

        let exporters = Set((environment["OTEL_TRACES_EXPORTER"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        config.console = exporters.contains("console")
        let signalEndpoint = environment["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"].flatMap(nonEmptyURL)
        let genericEndpoint = environment["OTEL_EXPORTER_OTLP_ENDPOINT"].flatMap(nonEmptyURL)
        let wantsOTLP = exporters.contains("otlp") || (exporters.isEmpty && (signalEndpoint ?? genericEndpoint) != nil)
        let protocolValue = environment["OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"] ??
            environment["OTEL_EXPORTER_OTLP_PROTOCOL"]
        config.otlpProtocol = protocolValue.flatMap(OTLPProtocol.init(rawValue:)) ?? .httpProtobuf
        if wantsOTLP {
            if let signalEndpoint {
                config.otlpEndpoint = signalEndpoint
                config.otlpEndpointIsSignalSpecific = true
            } else {
                config.otlpEndpoint = genericEndpoint
                    ?? URL(string: config.otlpProtocol == .grpc ? "http://localhost:4317" : "http://localhost:4318")
            }
        }
        config.otlpHeaders = parsePairs(environment["OTEL_EXPORTER_OTLP_HEADERS"])
            .merging(parsePairs(environment["OTEL_EXPORTER_OTLP_TRACES_HEADERS"])) { _, specific in specific }
        if let raw = environment["OTEL_EXPORTER_OTLP_TRACES_TIMEOUT"] ?? environment["OTEL_EXPORTER_OTLP_TIMEOUT"],
           let milliseconds = Int(raw), milliseconds > 0 {
            config.otlpTimeout = .milliseconds(milliseconds)
        }
        if let raw = environment["OTEL_BSP_SCHEDULE_DELAY"], let milliseconds = Int(raw), milliseconds > 0 {
            config.limits.scheduleDelay = .milliseconds(milliseconds)
        }
        if let raw = environment["OTEL_BSP_MAX_QUEUE_SIZE"], let size = Int(raw), size > 0 {
            config.limits.maxQueueSize = size
        }
        if let raw = environment["OTEL_BSP_MAX_EXPORT_BATCH_SIZE"], let size = Int(raw), size > 0 {
            config.limits.maxExportBatchSize = min(size, config.limits.maxQueueSize)
        }
        config.inheritedParent = environment["TRACEPARENT"].flatMap {
            SpanContext(traceparent: $0, traceState: environment["TRACESTATE"])
        }
        return config
    }

    /// Parses `key=value,key2=value2` with percent-decoding (resource attributes and headers).
    static func parsePairs(_ raw: String?) -> [String: String] {
        guard let raw else { return [:] }
        var pairs: [String: String] = [:]
        for item in raw.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            pairs[key.removingPercentEncoding ?? key] = value.removingPercentEncoding ?? value
        }
        return pairs
    }

    private static func nonEmptyURL(_ raw: String) -> URL? {
        raw.isEmpty ? nil : URL(string: raw)
    }
}

/// Process-wide OpenTelemetry setup for amoo executables.
public enum AmooTelemetry {
    /// Handle returned by ``bootstrap(_:)``; call ``Handle/shutdown()`` before the process exits.
    public final class Handle: Sendable {
        public let processor: SpanBatchProcessor?
        public let localDirectory: URL?
        public let exporterNames: [String]

        init(processor: SpanBatchProcessor?, localDirectory: URL?, exporterNames: [String]) {
            self.processor = processor
            self.localDirectory = localDirectory
            self.exporterNames = exporterNames
        }

        public func flush() async {
            await processor?.flush()
        }

        public func shutdown() async {
            await processor?.shutdown()
        }
    }

    private static let logger = AmooLogger.forType(Self.self)

    /// Builds the tracer and exporters and installs them as the global tracer. Call once per process.
    @discardableResult
    public static func bootstrap(_ configuration: TelemetryConfiguration) -> Handle {
        guard let processor = makeProcessor(configuration) else {
            return Handle(processor: nil, localDirectory: nil, exporterNames: [])
        }
        InstrumentationSystem.bootstrap(AmooTracer(
            processor: processor.processor,
            defaultParent: configuration.inheritedParent
        ))
        logger.debug("Telemetry bootstrapped", context: "exporters=\(processor.names.joined(separator: ","))")
        return Handle(
            processor: processor.processor, localDirectory: configuration.localDirectory,
            exporterNames: processor.names
        )
    }

    /// Builds a tracer without installing it globally (tests and embedded hosts).
    public static func makeTracer(_ configuration: TelemetryConfiguration) -> (tracer: AmooTracer, handle: Handle)? {
        guard let processor = makeProcessor(configuration) else { return nil }
        let tracer = AmooTracer(processor: processor.processor, defaultParent: configuration.inheritedParent)
        return (
            tracer,
            Handle(
                processor: processor.processor,
                localDirectory: configuration.localDirectory,
                exporterNames: processor.names
            )
        )
    }

    /// Builds a tracer around caller-supplied exporters (tests).
    public static func makeTracer(
        exporters: [any SpanExporter],
        resource: TelemetryResource,
        limits: SpanBatchProcessor.Limits = .init(),
        defaultParent: SpanContext? = nil
    ) -> (tracer: AmooTracer, processor: SpanBatchProcessor) {
        let processor = SpanBatchProcessor(exporters: exporters, resource: resource, limits: limits)
        return (AmooTracer(processor: processor, defaultParent: defaultParent), processor)
    }

    /// The OpenTelemetry resource for `configuration`.
    public static func resource(_ configuration: TelemetryConfiguration) -> TelemetryResource {
        var attributes: [String: TelemetryValue] = configuration.resourceAttributes.mapValues(TelemetryValue.string)
        attributes["service.name"] = .string(configuration.serviceName)
        attributes["service.version"] = .string(configuration.serviceVersion)
        attributes["telemetry.sdk.name"] = .string("amoo")
        attributes["telemetry.sdk.language"] = .string("swift")
        attributes["telemetry.sdk.version"] = .string(configuration.serviceVersion)
        attributes["process.pid"] = .int(Int64(ProcessInfo.processInfo.processIdentifier))
        #if os(macOS)
        attributes["os.type"] = .string("darwin")
        #elseif os(Linux)
        attributes["os.type"] = .string("linux")
        #endif
        return TelemetryResource(attributes: attributes, scopeVersion: configuration.serviceVersion)
    }

    private static func makeProcessor(
        _ configuration: TelemetryConfiguration
    ) -> (processor: SpanBatchProcessor, names: [String])? {
        guard !configuration.disabled else { return nil }
        var exporters: [any SpanExporter] = []
        if let directory = configuration.localDirectory {
            exporters.append(OTLPFileExporter(directory: directory))
        }
        if configuration.console {
            exporters.append(OTLPConsoleExporter())
        }
        if let endpoint = configuration.otlpEndpoint {
            do {
                try exporters.append(remoteExporter(endpoint: endpoint, configuration: configuration))
            } catch {
                logger.error(
                    "OTLP exporter configuration failed",
                    error: error,
                    context: "feature=telemetry action=bootstrap protocol=\(configuration.otlpProtocol.rawValue)"
                )
            }
        }
        guard !exporters.isEmpty else { return nil }
        let processor = SpanBatchProcessor(
            exporters: exporters, resource: resource(configuration), limits: configuration.limits
        )
        return (processor, exporters.map(\.name))
    }

    private static func remoteExporter(
        endpoint: URL,
        configuration: TelemetryConfiguration
    ) throws -> any SpanExporter {
        switch configuration.otlpProtocol {
        case .grpc:
            let secure = endpoint.scheme == "https"
            return try OTLPGRPCExporter(
                host: endpoint.host ?? "localhost", port: endpoint.port ?? (secure ? 443 : 4317), secure: secure,
                headers: configuration.otlpHeaders, timeout: configuration.otlpTimeout
            )
        case .httpProtobuf, .httpJSON:
            let url = configuration.otlpEndpointIsSignalSpecific
                ? endpoint : endpoint.appending(path: "v1/traces")
            return OTLPHTTPExporter(
                endpoint: url, encoding: configuration.otlpProtocol == .httpJSON ? .json : .protobuf,
                headers: configuration.otlpHeaders, timeout: configuration.otlpTimeout
            )
        }
    }
}

// swiftlint:enable multiline_arguments
