import ProcessRunner
import SwiftyShell
import XCTest

final class AndroidCLIRunnerTests: XCTestCase {
    func testLayoutUsesTypedCommandAndParsesElements() async throws {
        let mock = MockShellExecutor(result: .init(
            exitCode: 0,
            stdout: """
            [{"text":"Run","resource-id":"run","content-desc":"run-action","center":"[10,20]","off-screen":false}]
            """,
            stderr: ""
        ))
        let runner = AndroidCLIRunner(context: mock.context, sdkPath: "/opt/android-sdk")

        let elements = try await runner.layout(device: "emulator-5554", diff: true)

        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0].text, "Run")
        XCTAssertEqual(elements[0].resourceID, "run")
        XCTAssertEqual(elements[0].contentDescription, "run-action")
        XCTAssertEqual(elements[0].center, "[10,20]")
        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands, [[
            "android", "--sdk=/opt/android-sdk", "layout", "--diff", "--device=emulator-5554"
        ]])
    }

    func testAnnotatedCaptureAndResolution() async throws {
        let mock = MockShellExecutor(results: [
            .init(exitCode: 0, stdout: "", stderr: ""),
            .init(exitCode: 0, stdout: "tap 120 340\n", stderr: "")
        ])
        let runner = AndroidCLIRunner(context: mock.context)

        try await runner.captureScreen(
            device: "emulator-5554",
            output: "/tmp/screen.png",
            annotated: true
        )
        let resolved = try await runner.resolveScreen(
            screenshot: "/tmp/screen.png",
            instruction: "tap #4"
        )

        XCTAssertEqual(resolved, "tap 120 340")
        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands[0], [
            "android", "screen", "capture", "--annotate", "--device=emulator-5554",
            "--output=/tmp/screen.png"
        ])
        XCTAssertEqual(commands[1], [
            "android", "screen", "resolve", "--screenshot=/tmp/screen.png", "--string=tap #4"
        ])
    }
}
