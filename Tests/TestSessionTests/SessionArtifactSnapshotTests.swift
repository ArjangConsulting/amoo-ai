import AmooCore
import Foundation
import TestCommons
@testable import TestSession
import XCTest

private actor SnapshotBootstrapper: SessionBootstrapper {
    let source: URL
    var installedPath: String?
    var installedBytes: Data?

    init(source: URL) {
        self.source = source
    }

    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
        installedPath = request.buildPath
        try FileManager.default.removeItem(at: source)
        if let path = request.buildPath {
            installedBytes = try Data(contentsOf: URL(fileURLWithPath: path).appending(path: "Demo"))
        }
        return BootstrapResult(driver: SnapshotDriver(), deviceID: "phone", platform: .ios, cleanup: {})
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        []
    }
}

private struct SnapshotDriver: PlatformDriver {}

final class SessionArtifactSnapshotTests: XCTestCase {
    private func makeBundle(in root: URL, executable: Bool = true) throws -> URL {
        let bundle = root.appending(path: "Demo.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "com.example.demo", "CFBundleExecutable": "Demo"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Info.plist"))
        if executable {
            let binary = bundle.appending(path: "Demo")
            try Data("complete executable".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        return bundle
    }

    func testSourceCanDisappearDuringBootstrapWithoutChangingInstalledSnapshot() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let bundle = try makeBundle(in: scratch.url)
        let bootstrapper = SnapshotBootstrapper(source: bundle)
        let store = FileSessionStore(root: scratch.url.appending(path: "sessions"))
        let manager = SessionManager(bootstrapper: bootstrapper, idGenerator: { "snapshot-session" }, store: store)
        let session = try await manager.startSession(appID: "com.example.demo", platform: .ios, buildPath: bundle.path)
        let installedPath = await bootstrapper.installedPath
        let installedBytes = await bootstrapper.installedBytes
        XCTAssertEqual(installedPath, store.directory(for: session.id).appending(path: "build/Demo.app").path)
        XCTAssertEqual(installedBytes, Data("complete executable".utf8))
        XCTAssertEqual(session.artifactSnapshot?.sha256, session.appArtifactSHA256)
        try await manager.endSession(session.id)
        let reloaded = await store.loadReport(sessionID: session.id)
        XCTAssertEqual(reloaded?.artifactSnapshot, session.artifactSnapshot)
        XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(installedPath)))
    }

    func testIncompleteBundleFailsBeforeBootstrapAndReportsSnapshotStage() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let bundle = try makeBundle(in: scratch.url, executable: false)
        let bootstrapper = SnapshotBootstrapper(source: bundle)
        let manager = SessionManager(bootstrapper: bootstrapper)
        do {
            _ = try await manager.startSession(appID: "com.example.demo", platform: .ios, buildPath: bundle.path)
            XCTFail("Incomplete bundle must not reach device installation")
        } catch {
            XCTAssertEqual((error as? any SessionStartupFailure)?.startupStage, "artifact_snapshot")
        }
        let installedPath = await bootstrapper.installedPath
        XCTAssertNil(installedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testWrongBundleIdentityAndTruncatedArchiveAreRejected() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let bundle = try makeBundle(in: scratch.url)
        let destination = scratch.url.appending(path: "snapshot")
        XCTAssertThrowsError(try AppArtifactSnapshot.create(
            source: bundle.path, platform: .ios, appID: "different.app", directory: destination
        ))
        let apk = scratch.url.appending(path: "truncated.apk")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: apk)
        XCTAssertThrowsError(try AppArtifactSnapshot.create(
            source: apk.path, platform: .android, appID: "com.example.demo", directory: destination
        ))
    }
}
