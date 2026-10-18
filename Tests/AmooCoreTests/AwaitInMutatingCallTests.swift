import Foundation
import XCTest

/// A value-type mutation whose arguments `await` — `await list.append(await work())` — holds a mutable
/// access across a suspension. Release builds abort on it with "freed pointer was not the last
/// allocation", which is how Homebrew 0.2.1 died on `preflight` and on the first MCP device call.
/// Debug builds never show it, so this reads the source instead of waiting for a release to crash.
final class AwaitInMutatingCallTests: XCTestCase {
    private static let mutators = "append|insert|merge|updateValue|formUnion|formIntersection|removeAll|replaceSubrange"

    func testNoSourceAwaitsInsideAValueMutationsArguments() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no sources under \(sources.path)")

        let call = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_.]*\.("# + Self
            .mutators + #")\("#)
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let ns = text as NSString
            for match in call.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let lineStart = ns.lineRange(for: NSRange(location: match.range.location, length: 0))
                let prefix = ns.substring(with: NSRange(
                    location: lineStart.location,
                    length: match.range.location - lineStart.location
                ))
                // Comments quoting the bad pattern are not code.
                if prefix.contains("//") {
                    continue
                }
                let arguments = Self.arguments(in: ns, from: match.range.location + match.range.length)
                let awaitedReceiver = prefix.range(of: #"\bawait\s+$"#, options: .regularExpression) != nil
                if awaitedReceiver || arguments.range(of: #"\bawait\b"#, options: .regularExpression) != nil {
                    let line = ns.substring(to: match.range.location).components(separatedBy: "\n").count
                    offenders.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")):\(line)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "Evaluate the awaited value into a local first, then mutate.")
    }

    private static func arguments(in text: NSString, from start: Int) -> String {
        var depth = 1
        var index = start
        while index < text.length, depth > 0 {
            // 40 and 41 are the UTF-16 code units for ( and ).
            switch text.character(at: index) {
            case 40: depth += 1
            case 41: depth -= 1
            default: break
            }
            index += 1
        }
        return text.substring(with: NSRange(location: start, length: max(0, index - 1 - start)))
    }
}
