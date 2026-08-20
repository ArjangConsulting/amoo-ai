import Foundation
import StudioProtocol
import Testing

@Suite("Studio protocol")
struct StudioProtocolTests {
    @Test("handshake reports the protocol version and capabilities")
    func handshake() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"system.handshake","params":{}}"#.utf8)
        let response = await StudioService().handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["protocolVersion"] as? Int == StudioService.protocolVersion)
        #expect(result["product"] as? String == "amoo")
        #expect(result["capabilities"] as? [String] == [
            "health", "devices.list", "devices.start", "devices.create",
            "apps.buildInstallRun", "apps.reinstallRun", "apps.resetData"
        ])
    }

    @Test("unknown methods return JSON-RPC method-not-found")
    func methodNotFound() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":"abc","method":"missing"}"#.utf8)
        let response = await StudioService().handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(error["code"] as? Int == -32601)
    }

    @Test("device list is returned as structured protocol data")
    func deviceList() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"devices.list","params":{}}"#.utf8)
        let response = await StudioService(workspace: StubWorkspace()).handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let devices = try #require(result["devices"] as? [[String: Any]])
        #expect(devices.first?["id"] as? String == "sim-1")
        #expect(devices.first?["status"] as? String == "Running")
    }

    @Test("device creation is routed through the typed workspace")
    func deviceCreation() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":3,"method":"devices.create","params":{"platform":"android","name":"Amoo Pixel","runtime":"system-images;android-36;google_apis;arm64-v8a","deviceType":"pixel_9"}}"#.utf8)
        let response = await StudioService(workspace: StubWorkspace()).handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["message"] as? String == "created Amoo Pixel")
    }
}

private struct StubWorkspace: StudioDeviceWorkspace {
    func listDevices() async -> [StudioDevice] { [.init(id: "sim-1", name: "iPhone", platform: .ios, osVersion: "26.0", status: .running, physical: false)] }
    func startDevice(_: String) async -> StudioOperationResult { .init(message: "started", artifactPath: nil) }
    func createDevice(_ request: StudioCreateDeviceRequest) async -> StudioOperationResult { .init(message: "created \(request.name)", artifactPath: nil) }
    func buildInstallRun(_: StudioAppRequest) async -> StudioOperationResult { .init(message: "built", artifactPath: "/tmp/App.app") }
    func reinstallRun(_: StudioAppRequest) async -> StudioOperationResult { .init(message: "installed", artifactPath: nil) }
    func resetData(_: StudioAppRequest) async -> StudioOperationResult { .init(message: "reset", artifactPath: nil) }
}
