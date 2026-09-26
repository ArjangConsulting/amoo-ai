import Foundation
@testable import WebInspector
import XCTest

/// Scripted `adb`: answers by subcommand and records every invocation.
private actor ScriptedADB: WebInspectorShell {
    private(set) var calls: [[String]] = []
    let procNetUnix: String
    let pidof: String
    let forwardList: String

    init(procNetUnix: String, pidof: String = "", forwardList: String = "") {
        self.procNetUnix = procNetUnix
        self.pidof = pidof
        self.forwardList = forwardList
    }

    func run(_ arguments: [String]) async throws -> WebInspectorShellResult {
        calls.append(arguments)
        let tail = arguments.drop { $0 == "adb" || $0 == "-s" || $0.hasPrefix("emulator-") }
        switch Array(tail.prefix(2)) {
        case ["shell", "cat"]: return .init(exitCode: 0, stdout: procNetUnix, stderr: "")
        case ["shell", "pidof"]: return .init(exitCode: pidof.isEmpty ? 1 : 0, stdout: pidof, stderr: "")
        case ["forward", "--list"]: return .init(exitCode: 0, stdout: forwardList, stderr: "")
        case ["forward", "tcp:0"]: return .init(exitCode: 0, stdout: "40123\n", stderr: "")
        default: return .init(exitCode: 0, stdout: "", stderr: "")
        }
    }
}

final class AndroidWebInspectingTests: XCTestCase {
    private let sockets = """
    Num       RefCount Protocol Flags    Type St Inode Path
    0000: 00000002 00000000 00010000 0001 01 1 @webview_devtools_remote_111
    0000: 00000002 00000000 00010000 0001 01 2 @webview_devtools_remote_222
    """

    private func resolver(_ adb: ScriptedADB) -> PlatformWebInspecting {
        PlatformWebInspecting(shell: adb, environment: [:])
    }

    /// Regression: with a physical phone and an emulator attached, unscoped `adb` failed with
    /// "more than one device/emulator" (or reached the wrong device).
    func testEveryADBCallIsScopedToTheSerial() async throws {
        let adb = ScriptedADB(procNetUnix: sockets, pidof: "222\n")
        let client = try await resolver(adb).client(platform: .android, bundleID: "com.app", deviceID: "emulator-5554")
        await client.close()

        let calls = await adb.calls
        XCTAssertFalse(calls.isEmpty)
        for call in calls {
            XCTAssertEqual(Array(call.prefix(3)), ["adb", "-s", "emulator-5554"], "\(call)")
        }
    }

    func testPicksTheSocketOwnedByTheApp() async throws {
        let adb = ScriptedADB(procNetUnix: sockets, pidof: "222 223\n")
        _ = try await resolver(adb).client(platform: .android, bundleID: "com.app", deviceID: "emulator-5554")

        let forward = await adb.calls.first { $0.contains("tcp:0") }
        XCTAssertEqual(forward?.last, "localabstract:webview_devtools_remote_222")
    }

    /// Another app's WebView must not answer for this one.
    func testAppWithoutAWebViewSocketIsReportedNotSubstituted() async {
        let inspector = resolver(ScriptedADB(procNetUnix: sockets, pidof: "999\n"))
        do {
            _ = try await inspector.client(platform: .android, bundleID: "com.app", deviceID: "emulator-5554")
            XCTFail("expected noInspectableWebViews")
        } catch {
            XCTAssertEqual(error as? WebInspectorError, .noInspectableWebViews(bundleID: "com.app"))
        }
    }

    /// A dead app has no socket either; say so instead of blaming web-debugging settings.
    func testStoppedAppIsReportedAsNotRunning() async {
        let inspector = resolver(ScriptedADB(procNetUnix: sockets, pidof: ""))
        do {
            _ = try await inspector.client(platform: .android, bundleID: "com.app", deviceID: "emulator-5554")
            XCTFail("expected appNotRunning")
        } catch {
            XCTAssertEqual(error as? WebInspectorError, .appNotRunning(bundleID: "com.app"))
        }
    }

    /// Regression: each call leaked an `adb forward tcp:<n> localabstract:…` that was never removed.
    func testCloseRemovesTheForwardAndStaleForwardsAreSwept() async throws {
        let forwards = """
        emulator-5554 tcp:39001 localabstract:webview_devtools_remote_77
        emulator-5554 tcp:39002 localabstract:webview_devtools_remote_111
        adb-PIXEL tcp:39003 localabstract:webview_devtools_remote_55
        emulator-5554 tcp:22088 tcp:22088
        """
        let adb = ScriptedADB(procNetUnix: sockets, forwardList: forwards)
        let client = try await resolver(adb).client(platform: .android, bundleID: nil, deviceID: "emulator-5554")
        await client.close()

        let removed = await adb.calls.filter { $0.contains("--remove") }.compactMap(\.last)
        // Dead pid 77 is swept; live 111, the other device's, and the companion's are left alone.
        XCTAssertEqual(removed, ["tcp:39001", "tcp:40123"])
    }

    func testStaleForwardParsing() {
        XCTAssertEqual(
            PlatformWebInspecting.staleForwardPorts(
                in: "emulator-5554 tcp:1 localabstract:webview_devtools_remote_9\n",
                serial: "emulator-5554",
                liveSockets: ["webview_devtools_remote_9"]
            ),
            []
        )
        XCTAssertEqual(PlatformWebInspecting.adbPrefix(serial: nil), ["adb"])
        XCTAssertEqual(PlatformWebInspecting.adbPrefix(serial: "booted"), ["adb"])
    }
}
