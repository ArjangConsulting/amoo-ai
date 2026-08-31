import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Compares full emitter output against checked-in fixtures, so a change to an emitter's
/// output shape shows up as a reviewable file diff instead of only a pass/fail from the
/// substring assertions in `TestCodeGeneratorTests`.
///
/// To intentionally update the golden files after a deliberate emitter change, run:
///   AMOO_RECORD_GOLDENS=1 swift test --filter GoldenFixtureTests
/// then review the resulting diff under Fixtures/ like any other code change.
final class GoldenFixtureTests: XCTestCase {
    private struct Fixture {
        let name: String
        let emitter: any StudioCodeEmitting
        let expectedExtension: String
    }

    private static let fixtures: [Fixture] = [
        Fixture(name: "sign-in-flow-ios", emitter: XCUITestEmitter(), expectedExtension: "swift"),
        Fixture(name: "sign-in-flow-android", emitter: EspressoEmitter(), expectedExtension: "kt"),
        Fixture(name: "all-tools-ios", emitter: XCUITestEmitter(), expectedExtension: "swift"),
        Fixture(name: "all-tools-android", emitter: EspressoEmitter(), expectedExtension: "kt"),
        // The documented app-owned test context from docs/test-context.md — pins the full
        // generated scaffold (import, base class, no duplicate app.launch(), super chaining) so
        // the doc's "Complete XCUITest example" cannot silently drift from the emitter.
        Fixture(name: "context-example-ios", emitter: XCUITestEmitter(), expectedExtension: "swift")
    ]

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    func testGeneratedOutputMatchesGoldenFixtures() throws {
        let recording = ProcessInfo.processInfo.environment["AMOO_RECORD_GOLDENS"] == "1"
        var recordedAny = false

        for fixture in Self.fixtures {
            let inputURL = fixturesDirectory.appendingPathComponent("\(fixture.name).json")
            let expectedURL = fixturesDirectory
                .appendingPathComponent("\(fixture.name).\(fixture.expectedExtension).golden")

            let inputData = try Data(contentsOf: inputURL)
            let test = try JSONDecoder().decode(StudioAuthoredTest.self, from: inputData)
            let actual = try fixture.emitter.generate(test).source

            if recording {
                try actual.write(to: expectedURL, atomically: true, encoding: .utf8)
                recordedAny = true
                continue
            }

            guard let expectedData = try? Data(contentsOf: expectedURL),
                  let expected = String(data: expectedData, encoding: .utf8)
            else {
                XCTFail("Missing golden fixture at \(expectedURL.path). Run with AMOO_RECORD_GOLDENS=1 to create it.")
                continue
            }

            XCTAssertEqual(
                actual,
                expected,
                "Generated output for '\(fixture.name)' no longer matches its golden fixture."
                    + " If this change is intentional, rerun with AMOO_RECORD_GOLDENS=1 to update it."
            )
        }

        if recordedAny {
            throw XCTSkip("Golden fixtures were (re)recorded — rerun without AMOO_RECORD_GOLDENS to verify them.")
        }
    }
}
