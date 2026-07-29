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
    ///
    /// Binds to the loopback interface — the host driver reaches the simulator
    /// via the shared host network, and on a real device the host port-forwards
    /// over USB. Exposing the companion on every interface would let any device
    /// on the network drive XCUITest gestures (taps, types, screenshots).
    func run() async throws {
        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: port),
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
