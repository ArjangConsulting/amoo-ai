import AmooCore
import Protos

public extension GRPCCompanionClient {
    /// Asks the companion to size and encode the capture; older companions ignore the fields and
    /// return native pixels, which `appliedScale == nil` reports.
    func takeScreenshot(options: ScreenshotRequestOptions) async throws -> ScreenshotData {
        var request = Amoo_ScreenshotRequest()
        request.format = options.format.rawValue
        request.scale = options.scale ?? 0
        request.pointResolution = options.pointResolution
        request.quality = options.quality ?? 0
        let response = try await rpcClient.takeScreenshot(request)
        let screen = response.screen
        let geometry = response.hasScreen && screen.widthPoints > 0
            ? ScreenSize(
                widthPoints: screen.widthPoints,
                heightPoints: screen.heightPoints,
                widthPixels: screen.widthPixels,
                heightPixels: screen.heightPixels,
                scale: screen.scale
            ) : nil
        return ScreenshotData(
            bytes: [UInt8](response.data),
            format: response.format == "jpeg" ? .jpeg : .png,
            appliedScale: response.appliedScale > 0 && response.appliedScale < 1 ? response.appliedScale : nil,
            density: response.density > 0 ? response.density : nil,
            geometry: geometry
        )
    }
}
