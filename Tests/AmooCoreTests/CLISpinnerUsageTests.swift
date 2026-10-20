import Foundation
import XCTest

/// SwiftyTerminal's `withSpinner` aborts release builds from Xcode 26.6 (Swift 6.3) with "freed
/// pointer was not the last allocation" — it failed the release smoke gate on
/// `amoo device current_app`. Debug builds and newer compilers never show it, so this reads the
/// source instead of waiting for a release to crash. Use `withCLISpinner` instead.
final class CLISpinnerUsageTests: XCTestCase {
    func testNoSourceCallsSwiftyTerminalWithSpinner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no sources under \(sources.path)")

        let call = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])withSpinner\s*\("#)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                let range = NSRange(location: 0, length: (code as NSString).length)
                if call.firstMatch(in: code, range: range) != nil {
                    offenders.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Call withCLISpinner (Sources/CLI/CLISpinner.swift) instead.")
    }
}
