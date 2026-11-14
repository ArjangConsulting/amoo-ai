@testable import CLI
import Foundation
import StudioProtocol
import TestCommons
import XCTest

final class InitScreenshotsTests: XCTestCase {
    func testFlagsParseAndRejectConflictsOrBadScales() throws {
        let request = try parseInitRequest(["--screenshot-scale", "0.5", "--screenshot-path-only"])
        XCTAssertEqual(request.screenshotScale, 0.5)
        XCTAssertEqual(request.screenshotInline, false)
        XCTAssertThrowsError(try parseInitRequest(["--screenshot-scale", "0"]))
        XCTAssertThrowsError(try parseInitRequest(["--screenshot-scale", "1.5"]))
        XCTAssertThrowsError(try parseInitRequest(["--screenshot-inline", "--screenshot-path-only"]))
    }

    func testFlagsKeepTheUnsetPartOfTheCurrentPolicy() throws {
        let current = ScreenshotPolicy(scale: 0.25, returnImage: true)
        XCTAssertNil(try initScreenshotPolicy(parseInitRequest([]), current: current))
        let request = try parseInitRequest(["--screenshot-path-only"])
        XCTAssertEqual(
            initScreenshotPolicy(request, current: current),
            ScreenshotPolicy(scale: 0.25, returnImage: false)
        )
    }

    func testGuidedQuestionsStartFromTheCurrentPolicy() {
        let prompter = ScriptedPrompter()
        prompter.choices = [1, 0]
        let chosen = askInitScreenshotPolicy(
            current: ScreenshotPolicy(scale: 0.25, returnImage: true),
            prompter: prompter
        )
        XCTAssertEqual(chosen, ScreenshotPolicy(scale: 0.5, returnImage: false))

        let cancelled = ScriptedPrompter()
        cancelled.choices = [nil, nil]
        let kept = askInitScreenshotPolicy(current: ScreenshotPolicy(scale: 0.25), prompter: cancelled)
        XCTAssertEqual(kept, ScreenshotPolicy(scale: 0.25))
    }

    func testApplyWritesOnlyAChangedPolicyAtTheRepositoryRoot() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try FileManager.default.createDirectory(
            at: scratch.url.appending(path: ".git"), withIntermediateDirectories: true
        )
        let file = scratch.url.appending(path: AmooProjectConfig.fileName)
        XCTAssertNil(applyInitScreenshotPolicy(.standard, current: .standard, root: scratch.url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let half = ScreenshotPolicy(scale: 0.5)
        let note = try XCTUnwrap(applyInitScreenshotPolicy(half, current: .standard, root: scratch.url))
        XCTAssertTrue(note.contains("0.5 × 1 pixel per point, file path only"), note)
        XCTAssertEqual(ScreenshotPolicy.resolve(from: scratch.url), half)
    }

    func testHeadlessFlagsSaveWithoutAskingAndJSONStaysQuiet() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try FileManager.default.createDirectory(
            at: scratch.url.appending(path: ".git"), withIntermediateDirectories: true
        )
        let prompter = ScriptedPrompter()
        let plain = try parseInitRequest(["--screenshot-scale", "0.25"])
        let note = settleInitScreenshots(plain, interactive: false, root: scratch.url, prompter: prompter)
        XCTAssertNotNil(note)
        XCTAssertTrue(prompter.transcript.isEmpty)
        XCTAssertEqual(ScreenshotPolicy.resolve(from: scratch.url).scale, 0.25)

        let json = try parseInitRequest(["--screenshot-inline", "--json"])
        XCTAssertNil(settleInitScreenshots(json, interactive: false, root: scratch.url, prompter: prompter))
        XCTAssertEqual(ScreenshotPolicy.resolve(from: scratch.url), ScreenshotPolicy(scale: 0.25, returnImage: true))
        XCTAssertNil(try settleInitScreenshots(
            parseInitRequest([]),
            interactive: false,
            root: scratch.url,
            prompter: prompter
        ))
        XCTAssertTrue(prompter.transcript.isEmpty)
    }

    func testAgentsBlockReportsTheScreenshotPolicy() {
        let block = renderInitLocationsBlock(
            InitSavedLocations(platform: .ios),
            relativeTo: "/repo",
            screenshots: ScreenshotPolicy(scale: 0.5, returnImage: true)
        )
        XCTAssertTrue(block.contains("- Screenshots: 0.5 × 1 pixel per point, returned inline"), block)
        XCTAssertTrue(block.contains("Batch independent assertions in one `run_steps`"), block)
    }
}
