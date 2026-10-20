import Foundation
@testable import TestSession
import XCTest

final class DeviceAccessRegistryTests: XCTestCase {
    func testOnlyOwningSessionCanReleaseDeviceAccess() async throws {
        let registry = DeviceAccessRegistry()
        let owner = try await registry.acquire("SIM")
        await registry.release("SIM", owner: UUID())
        do {
            _ = try await registry.acquire("SIM")
            XCTFail("A different session must not remove the owner's access")
        } catch DeviceAccessRegistry.AccessError.busy {}
        await registry.release("SIM", owner: owner)
        let next = try await registry.acquire("SIM")
        XCTAssertNotEqual(next, owner)
        await registry.release("SIM", owner: owner)
        do {
            _ = try await registry.acquire("SIM")
            XCTFail("Late cleanup must not remove a new session's access")
        } catch DeviceAccessRegistry.AccessError.busy {}
        await registry.release("SIM", owner: next)
    }
}
