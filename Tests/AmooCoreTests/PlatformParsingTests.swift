import AmooCore
import Foundation
import XCTest

final class PlatformParsingTests: XCTestCase {
    func testLenientSpellingsOfMacOSParse() {
        for raw in ["macos", "macOS", "MacOS", "mac", "osx"] {
            XCTAssertEqual(Platform(lenient: raw), .macos, raw)
        }
    }

    /// `macos` must not be read as iOS, and adding it must not change how the mobile spellings parse.
    func testMobileSpellingsAreUnchanged() {
        XCTAssertEqual(Platform(lenient: "iOS"), .ios)
        XCTAssertEqual(Platform(lenient: "ios-simulator"), .ios)
        XCTAssertEqual(Platform(lenient: "Android"), .android)
        XCTAssertEqual(Platform(lenient: "android-emulator"), .android)
        XCTAssertNil(Platform(lenient: "web"))
    }

    func testDecodesMacOSFromARecordedSession() throws {
        let decoded = try JSONDecoder().decode([Platform].self, from: Data(#"["macOS"]"#.utf8))
        XCTAssertEqual(decoded, [.macos])
    }
}
