import AmooCore
import CompanionProtocol
import ProcessRunner

/// Check the actual API, with a short RPC deadline. TCP alone may be an adb forward or stale listener.
func isCompanionReady(host: String, port: Int) async -> Bool {
    guard await isTCPPortReachable(host: host, port: port, timeoutSeconds: 0.5),
          let client = try? GRPCCompanionClient.makeLive(connection: CompanionConnection(host: host, port: port))
    else { return false }
    let capabilities = try? await client.getCapabilities()
    await client.shutdown()
    return capabilities?.contains { $0.key == "protocol.amoo.v1" && $0.supported } == true
}
