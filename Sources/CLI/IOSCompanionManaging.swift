import Foundation

protocol IOSCompanionManaging: Sendable {
    func ensureRunning(config: CompanionConfig, force: Bool) async throws
    /// Stops the companion this manager launched for `deviceUDID` after it has been idle `seconds`.
    func scheduleIdleShutdown(deviceUDID: String, after seconds: Double)
    /// Stops the companion this manager launched for `deviceUDID` now.
    func shutdown(deviceUDID: String) async
    /// Stops the companion for the device, whoever launched it, and frees its port.
    func resetCompanion(config: CompanionConfig) async -> String
    /// Stops this manager's companion for the device, and one an earlier, dead amoo left behind that
    /// this session adopted. A runner another live amoo process owns is left alone.
    func stopCompanion(config: CompanionConfig) async
}

extension IOSCompanionManaging {
    func scheduleIdleShutdown(deviceUDID _: String, after _: Double) {}
    func shutdown(deviceUDID _: String) async {}
    func resetCompanion(config _: CompanionConfig) async -> String {
        "nothing to reset"
    }

    func stopCompanion(config _: CompanionConfig) async {}
}
