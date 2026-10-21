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

    /// Lists elements like `find_elements`, routed by `session_id`, without recording the query.
    /// Studio's console completion uses it while a session records, so suggestions never become steps.
    func observeElements(arguments: [String: String]) async -> ToolResult {
        do {
            let driver = try await resolveDriver(arguments: arguments)
            return try await executeFindElements(arguments: arguments, driver: driver)
        } catch {
            return .error("Element query failed: \(error)")
        }
    }
}
