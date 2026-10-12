import AmooCore
@testable import CLI
import Foundation
import TestCommons
import XCTest

final class SessionDeviceClaimTests: XCTestCase {
    func testClaimExcludesOtherProcessAndReleasesWithoutUnlinking() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = DeviceLeaseStore(directory: scratch.url, reaper: { _ in })
        let claim = try SessionDeviceClaim(deviceID: "test-phone", store: store)
        let path = store.fileURL(deviceID: "test-phone").appendingPathExtension("session-lock").path
        XCTAssertEqual(try probeLock(path), 7)
        XCTAssertThrowsError(try SessionDeviceClaim(deviceID: "test-phone", store: store))
        XCTAssertThrowsError(try store.acquire(platform: .ios, deviceID: "test-phone", deviceName: nil, owner: nil))
        claim.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try probeLock(path), 0)
    }

    private func probeLock(_ path: String) throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = """
        import fcntl, sys
        with open(sys.argv[1], 'r+') as f:
            try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: sys.exit(7)
        """
        child.arguments = ["python3", "-c", script, path]
        try child.run()
        child.waitUntilExit()
        return child.terminationStatus
    }
}
