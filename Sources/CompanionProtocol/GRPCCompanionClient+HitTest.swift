import AmooCore
import GRPCCore
import Protos

public extension GRPCCompanionClient {
    /// Asks the companion's platform hit test whether a tap on `element` reaches it.
    ///
    /// A companion started before the `HitTest` RPC existed reports `.unsupported` rather than
    /// failing, so the caller keeps its own frame-based judgement.
    func hitTest(_ element: ElementInfo, appID: String?, candidateBundleIDs: [String]) async throws -> HitTestVerdict {
        var request = Amoo_HitTestRequest()
        request.id = element.id
        request.label = element.label
        if let frame = element.frame {
            var rect = Amoo_Rect()
            rect.x = frame.x
            rect.y = frame.y
            rect.width = frame.width
            rect.height = frame.height
            request.frame = rect
        }
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs
        let response: Amoo_HitTestResponse
        do {
            response = try await rpcClient.hitTest(request)
        } catch let error as RPCError where error.code == .unimplemented {
            return .unsupported
        } catch AmooError.notImplemented(_) {
            return .unsupported
        }
        return switch response.verdict {
        case .hittable: .hittable
        case .notHittable: .notHittable
        case .unresolved: .unresolved
        case .unspecified, .UNRECOGNIZED: .unsupported
        }
    }
}
