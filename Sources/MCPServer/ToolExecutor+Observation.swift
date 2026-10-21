import Foundation

public extension DriverToolExecutor {
    /// Captures a settled screenshot like `take_screenshot`, routed by `session_id`, without recording
    /// it into the session. Observers such as Studio's agent timeline use it, so their pictures never
    /// become steps in a generated test.
    func observeScreenshot(arguments: [String: String]) async -> ToolResult {
        do {
            let driver = try await resolveDriver(arguments: arguments)
            return try await executeTakeScreenshot(driver: driver, arguments: arguments)
        } catch {
            return .error("Screenshot failed: \(error)")
        }
    }
}
