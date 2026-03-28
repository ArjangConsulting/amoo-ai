public struct ServiceConfig: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String = "127.0.0.1", port: Int = 22087) {
        self.host = host
        self.port = port
    }
}
