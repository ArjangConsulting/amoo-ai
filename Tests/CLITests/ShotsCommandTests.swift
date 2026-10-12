@testable import CLI
import Foundation
import TestCommons
import XCTest

/// 20x10 white image with a `width`x`height` block of `colour` in the top-left corner.
private func testImage(block: (Int, Int)? = nil, grey: UInt8 = 0) -> ScreenshotBitmap {
    var bitmap = ScreenshotBitmap(width: 20, height: 10)
    guard let block else { return bitmap }
    for y in 0 ..< block.1 {
        for x in 0 ..< block.0 {
            let index = (y * bitmap.width + x) * 4
            bitmap.pixels[index] = grey
            bitmap.pixels[index + 1] = grey
            bitmap.pixels[index + 2] = grey
        }
    }
    return bitmap
}

/// The pure half of `amoo shots`: pixel comparison and sheet layout, which run on every platform.
final class ScreenshotComparisonTests: XCTestCase {
    private func image(block: (Int, Int)? = nil, grey: UInt8 = 0) -> ScreenshotBitmap {
        testImage(block: block, grey: grey)
    }

    // MARK: - comparison

    func testIdenticalImagesDoNotDiffAndAChangedBlockIsCounted() {
        let same = ScreenshotComparison.difference(image(), image())
        XCTAssertEqual(same?.changedPixels, 0)
        let changed = ScreenshotComparison.difference(image(), image(block: (10, 5)))
        XCTAssertEqual(changed?.changedPixels, 50)
        XCTAssertEqual(changed?.totalPixels, 200)
        XCTAssertEqual(changed?.ratio, 0.25)
    }

    func testToleranceAbsorbsSmallChannelNoise() {
        let slightlyOff = image(block: (20, 10), grey: 250)
        XCTAssertEqual(ScreenshotComparison.difference(image(), slightlyOff, tolerance: 8)?.changedPixels, 0)
        XCTAssertEqual(ScreenshotComparison.difference(image(), slightlyOff, tolerance: 2)?.changedPixels, 200)
    }

    func testDifferentSizesCannotBeCompared() {
        XCTAssertNil(ScreenshotComparison.difference(
            ScreenshotBitmap(width: 20, height: 10),
            ScreenshotBitmap(width: 21, height: 10)
        ))
    }

    func testOverlayPaintsChangedPixelsRedAndDimsTheRest() throws {
        let overlay = try XCTUnwrap(ScreenshotComparison.overlay(image(), image(block: (1, 1))))
        XCTAssertEqual(Array(overlay.pixels[0 ..< 4]), [255, 0, 0, 255])
        XCTAssertEqual(Array(overlay.pixels[4 ..< 8]), [255, 255, 255, 255])
    }

    // MARK: - layout

    func testLayoutSizesCellsToTheTallestImage() {
        let tall = ContactSheetEntry(caption: "tall", bitmap: ScreenshotBitmap(width: 100, height: 200))
        let wide = ContactSheetEntry(caption: "wide", bitmap: ScreenshotBitmap(width: 200, height: 100))
        let layout = ContactSheetLayout(entries: [tall, wide, tall, wide, tall], columns: 2, cellWidth: 100)
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.rows, 3)
        XCTAssertEqual(layout.cellHeight, 200, "the tallest aspect ratio decides")
        XCTAssertEqual(layout.origin(ofCell: 3).x, layout.padding + layout.cellWidth + layout.padding)
        XCTAssertEqual(
            layout.origin(ofCell: 3).y,
            layout.padding + (layout.cellHeight + layout.captionHeight + layout.padding)
        )
    }

    func testMoreColumnsThanImagesCollapsesToOneRow() {
        let one = ContactSheetEntry(caption: "a", bitmap: ScreenshotBitmap(width: 10, height: 10))
        let layout = ContactSheetLayout(entries: [one, one], columns: 8, cellWidth: 100)
        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.rows, 1)
    }
}

#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreText)
/// The file-based half: it encodes and decodes real PNGs, so it needs CoreGraphics.
final class ShotsCommandTests: XCTestCase {
    private func image(block: (Int, Int)? = nil, grey: UInt8 = 0) -> ScreenshotBitmap {
        testImage(block: block, grey: grey)
    }

    private func writePNG(_ bitmap: ScreenshotBitmap, to directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(bitmap.pngData(), "encode \(name)")
        try data.write(to: directory.appending(path: name))
    }

    // MARK: - commands

    func testMontageWritesOneSheetSizedToItsLayout() throws {
        let scratch = try makeScratchDirectory()
        let shots = scratch.url.appending(path: "shots")
        for name in ["01-home.png", "02-day.png", "10-reports.png"] {
            try writePNG(image(), to: shots, name: name)
        }
        let output = scratch.url.appending(path: "out/sheet.png")

        let result = runShotsCommand(args: [
            "montage",
            shots.path,
            "--out",
            output.path,
            "--columns",
            "2",
            "--cell-width",
            "100"
        ])

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("3 screenshot(s)"), result.output)
        let sheet = try XCTUnwrap(ScreenshotBitmap.load(from: output))
        let entries = (0 ..< 3).map { ContactSheetEntry(caption: "\($0)", bitmap: image()) }
        let layout = ContactSheetLayout(entries: entries, columns: 2, cellWidth: 100)
        XCTAssertEqual(sheet.width, layout.sheetWidth)
        XCTAssertEqual(sheet.height, layout.sheetHeight)
    }

    func testMontageOfAnEmptyFolderIsAnError() throws {
        let scratch = try makeScratchDirectory()
        XCTAssertEqual(runShotsCommand(args: ["montage", scratch.url.path]).exitCode, 1)
    }

    func testDiffReportsEveryKindOfChangeAndExitsOne() throws {
        let scratch = try makeScratchDirectory()
        let baseline = scratch.url.appending(path: "baseline")
        let current = scratch.url.appending(path: "current")
        try writePNG(image(), to: baseline, name: "same.png")
        try writePNG(image(), to: baseline, name: "changed.png")
        try writePNG(image(), to: baseline, name: "gone.png")
        try writePNG(image(), to: baseline, name: "resized.png")
        try writePNG(image(), to: current, name: "same.png")
        try writePNG(image(block: (10, 10)), to: current, name: "changed.png")
        try writePNG(ScreenshotBitmap(width: 30, height: 10), to: current, name: "resized.png")
        try writePNG(image(), to: current, name: "added.png")
        let diffs = scratch.url.appending(path: "diffs")

        let result = runShotsCommand(args: ["diff", baseline.path, current.path, "--out", diffs.path])

        XCTAssertEqual(result.exitCode, 1, result.output)
        XCTAssertTrue(result.output.contains("same     same.png"), result.output)
        XCTAssertTrue(result.output.contains("CHANGED  changed.png"), result.output)
        XCTAssertTrue(result.output.contains("MISSING  gone.png"), result.output)
        XCTAssertTrue(result.output.contains("SIZE     resized.png"), result.output)
        XCTAssertTrue(result.output.contains("NEW      added.png"), result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diffs.appending(path: "diff-changed.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diffs.appending(path: "diff-same.png").path))
    }

    func testMatchingFoldersPassAndANewFileIsAllowedOnRequest() throws {
        let scratch = try makeScratchDirectory()
        let baseline = scratch.url.appending(path: "baseline")
        let current = scratch.url.appending(path: "current")
        try writePNG(image(), to: baseline, name: "home.png")
        try writePNG(image(), to: current, name: "home.png")
        XCTAssertEqual(runShotsCommand(args: ["diff", baseline.path, current.path]).exitCode, 0)

        try writePNG(image(), to: current, name: "extra.png")
        XCTAssertEqual(runShotsCommand(args: ["diff", baseline.path, current.path]).exitCode, 1)
        XCTAssertEqual(runShotsCommand(args: ["diff", baseline.path, current.path, "--allow-new"]).exitCode, 0)
    }

    func testAThresholdAboveTheChangedShareLetsItPass() throws {
        let scratch = try makeScratchDirectory()
        let baseline = scratch.url.appending(path: "baseline")
        let current = scratch.url.appending(path: "current")
        try writePNG(image(), to: baseline, name: "home.png")
        try writePNG(image(block: (2, 1)), to: current, name: "home.png")
        XCTAssertEqual(runShotsCommand(args: ["diff", baseline.path, current.path]).exitCode, 1)
        XCTAssertEqual(runShotsCommand(args: ["diff", baseline.path, current.path, "--threshold", "0.05"]).exitCode, 0)
    }

    func testArgumentErrorsAreUsageErrors() {
        XCTAssertEqual(runShotsCommand(args: []).exitCode, 64)
        XCTAssertEqual(runShotsCommand(args: ["--help"]).exitCode, 0)
        for args in [
            ["montage"],
            ["diff", "a"],
            ["montage", "d", "--columns", "0"],
            ["diff", "a", "b", "--threshold", "2"],
            ["frobnicate"]
        ] {
            XCTAssertEqual(runShotsCommand(args: args).exitCode, 64, "\(args)")
        }
    }
}
#endif
