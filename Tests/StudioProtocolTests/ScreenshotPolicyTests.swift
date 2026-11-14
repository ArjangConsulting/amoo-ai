import Foundation
@testable import StudioProtocol
import TestCommons
import Testing

@Suite("amoo.config.json screenshots")
struct ScreenshotPolicyTests {
    @Test("a config without screenshots resolves to the standard policy")
    func missingSectionIsStandard() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try FileManager.default.createDirectory(
            at: scratch.url.appending(path: ".git"), withIntermediateDirectories: true
        )
        #expect(ScreenshotPolicy.resolve(from: scratch.url) == .standard)
        try Data(#"{"version": 1}"#.utf8).write(to: scratch.url.appending(path: AmooProjectConfig.fileName))
        #expect(ScreenshotPolicy.resolve(from: scratch.url) == .standard)
    }

    @Test("writing the policy keeps profiles and round-trips")
    func writeKeepsProfiles() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try FileManager.default.createDirectory(
            at: scratch.url.appending(path: ".git"), withIntermediateDirectories: true
        )
        let file = scratch.url.appending(path: AmooProjectConfig.fileName)
        try Data("""
        {"version": 1, "profiles": {"qa": {"apps": ["com.example"],
          "fields": {"email": {"literal": "qa@example.test", "class": "identifier"}}}}}
        """.utf8).write(to: file)
        let policy = ScreenshotPolicy(scale: 0.5, returnImage: true)
        try AmooProjectConfig.writeScreenshotPolicy(policy, to: file)
        let config = try AmooProjectConfig.load(file)
        #expect(config.screenshots == policy)
        #expect(config.profiles["qa"] != nil)
        #expect(ScreenshotPolicy.resolve(from: scratch.url) == policy)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"return_image\" : true"))
    }

    @Test("an out-of-range scale is a validation problem")
    func rejectsBadScale() throws {
        let config = try JSONDecoder().decode(
            AmooProjectConfig.self, from: Data(#"{"version": 1, "screenshots": {"scale": 2}}"#.utf8)
        )
        #expect(config.validationProblems() == ["screenshots.scale must be in (0, 1], got 2.0"])
    }

    @Test("an inner screenshots section replaces the outer one")
    func innerWins() {
        let outer = AmooProjectConfig(screenshots: ScreenshotPolicy(scale: 0.25))
        #expect(outer.overlaid(by: AmooProjectConfig()).screenshots == ScreenshotPolicy(scale: 0.25))
        let inner = AmooProjectConfig(screenshots: .standard)
        #expect(outer.overlaid(by: inner).screenshots == .standard)
    }
}
