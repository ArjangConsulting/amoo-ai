import AmooLogging

public extension AndroidDriver {
    func shutdown() async throws {
        let logger = AmooLogger.forType(Self.self)
        logger.info("Shutting down emulator", context: "action=shutdown state=requested")
        do {
            try await adb.killEmulator(serial: activeSerial)
            logger.info("Emulator shutdown verified", context: "action=shutdown state=stopped")
        } catch {
            logger.error("Emulator shutdown failed", error: error, context: "action=shutdown state=unverified")
            throw error
        }
    }
}
