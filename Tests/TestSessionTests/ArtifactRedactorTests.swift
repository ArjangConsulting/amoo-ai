import Foundation
@testable import TestSession
import XCTest

final class ArtifactRedactorTests: XCTestCase {
    func testShortSecretsAreRedactedOnlyAsWholeWords() {
        var redactor = ArtifactRedactor()
        redactor.register("hi")
        redactor.register("hunter22")
        XCTAssertEqual(
            redactor.redact("hitRegion: this field holds hi; token hunter22x"),
            "hitRegion: this field holds <redacted>; token <redacted>x"
        )
    }
}
