import Foundation

public enum MobileTestingError: Error, Sendable, Equatable {
    case notImplemented(String)
    case unsupportedCapability(key: String, reason: String)
    case timeout(operation: String, duration: Duration)
    case deviceNotFound(String)
    case appNotInstalled(appID: String)
    case commandFailed(command: String, output: String)
    case companionNotConnected
}
