import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Manages the gRPC server lifecycle for the iOS companion.
///
/// Uses grpc-swift v2 with NIO HTTP/2 transport. The server runs inside an
/// XCUITest target — the test method starts the server and blocks, keeping the
/// companion alive to accept commands from the host.
final class CompanionServer: Sendable {
    let port: Int
    private let provider: CompanionServiceProvider

    init(bridge: XCUITestBridge, port: Int = 22087) {
        self.port = port

        let touch = TouchHandler(bridge: bridge)
        let gesture = GestureHandler(bridge: bridge)
        let text = TextHandler(bridge: bridge)
        let accessibility = AccessibilityHandler(bridge: bridge)

        provider = CompanionServiceProvider(
            touch: touch,
            gesture: gesture,
            text: text,
            accessibility: accessibility
        )
    }

    /// Start the gRPC server and block until shutdown.
    func run() async throws {
        let transport = try HTTP2ServerTransport.Posix(
            address: .ipv4(host: "0.0.0.0", port: port),
            transportSecurity: .plaintext
        )

        let server = GRPCServer(
            transport: transport,
            services: [provider]
        )

        print("[CompanionServer] Listening on port \(port)")
        try await server.serve()
    }
}
