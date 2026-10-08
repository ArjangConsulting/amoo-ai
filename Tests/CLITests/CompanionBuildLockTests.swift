#if os(macOS)
@testable import CLI
import XCTest

final class CompanionBuildLockTests: XCTestCase {
    func testCompetingBuildCannotEnterAndReleaseAllowsNextOwner() async throws {
        let directory = try makeTemporaryDirectory()
        let first = try await CompanionBuildLock.acquire(directory: directory)
        do {
            _ = try await CompanionBuildLock.acquire(directory: directory, timeout: .milliseconds(100))
            XCTFail("A competing build must not acquire the shared lock")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Timed out"))
        }
        first.release()
        let next = try await CompanionBuildLock.acquire(directory: directory, timeout: .milliseconds(100))
        next.release()
    }

    func testCancelledWaitDoesNotReleaseAnotherOwnersLock() async throws {
        let directory = try makeTemporaryDirectory()
        let first = try await CompanionBuildLock.acquire(directory: directory)
        let waiter = Task { try await CompanionBuildLock.acquire(directory: directory) }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        first.release()
    }
}
#endif
