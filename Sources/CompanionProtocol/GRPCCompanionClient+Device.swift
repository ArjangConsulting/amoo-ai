import AmooCore
import GRPCCore
import Protos

/// Device-level controls, kept apart from the per-element RPCs in the actor's main body.
public extension GRPCCompanionClient {
    func setOrientation(_ orientation: DeviceOrientation) async throws -> DeviceOrientation {
        var request = Amoo_SetOrientationRequest()
        request.orientation = Amoo_Orientation(orientation)
        let reported: Amoo_Orientation
        do {
            reported = try await rpcClient.setOrientation(request).orientation
        } catch let error as RPCError where error.code == .unimplemented {
            // A companion started before this RPC existed keeps running until it is restarted.
            throw AmooError.unsupportedCapability(
                key: "action.setOrientation",
                reason: "the running companion predates it; restart it with `amoo companion start`"
            )
        }
        guard let result = DeviceOrientation(reported) else {
            throw AmooError.commandFailed(command: "setOrientation", output: "companion reported no orientation")
        }
        return result
    }

    func pressKey(_ key: KeyboardKey, modifiers: Set<KeyModifier>) async throws {
        var request = Amoo_PressKeyRequest()
        request.key = key.name
        request.modifiers = modifiers.sorted().map(\.rawValue)
        let response: Amoo_ActionResponse
        do {
            response = try await rpcClient.pressKey(request)
        } catch let error as RPCError where error.code == .unimplemented {
            throw AmooError.unsupportedCapability(
                key: "action.pressKey",
                reason: "the running companion predates it; restart it with `amoo companion start`"
            )
        }
        guard response.success else {
            throw AmooError.commandFailed(command: "pressKey \(key.name)", output: response.message)
        }
    }
}
