import AuditEngine
import MobileTestingCore

public struct DeviceService: Sendable {
    public var config: ServiceConfig

    public init(config: ServiceConfig = .init()) {
        self.config = config
    }

    public func health() -> String {
        "ok"
    }

    public func runAudit(_ engine: AuditEngine, input: AuditInput) async throws -> AuditReport {
        try await engine.run(input)
    }
}
