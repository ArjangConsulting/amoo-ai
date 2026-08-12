import Foundation

public enum AmooError: Error, Sendable, Equatable {
    case notImplemented(String)
    case unsupportedCapability(key: String, reason: String)
    case timeout(operation: String, duration: Duration)
    case deviceNotFound(String)
    case appNotInstalled(appID: String)
    case commandFailed(command: String, output: String)
    case companionNotConnected
    /// A required external tool is missing. `hint` should tell the user how to install it.
    case setupRequired(tool: String, hint: String)
}
