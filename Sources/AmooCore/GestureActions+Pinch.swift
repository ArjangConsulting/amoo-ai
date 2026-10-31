public extension GestureActions {
    /// Pinches with the fingers kept inside the whole screen.
    func pinch(center: Point, scale: Double, velocity: Double) async throws {
        try await pinch(center: center, scale: scale, velocity: velocity, bounds: nil)
    }
}
