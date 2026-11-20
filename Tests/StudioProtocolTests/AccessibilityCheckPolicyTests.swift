import Foundation
@testable import StudioProtocol
import TestCommons
import Testing

@Suite("amoo.config.json accessibility")
struct AccessibilityCheckPolicyTests {
    private func repository() throws -> TemporaryDirectory {
        let scratch = try TemporaryDirectory()
        try FileManager.default.createDirectory(
            at: scratch.url.appending(path: ".git"), withIntermediateDirectories: true
        )
        return scratch
    }

    @Test("a project without the section has opted in to nothing")
    func missingSectionIsNotConfigured() throws {
        let scratch = try repository()
        defer { try? scratch.remove() }
        #expect(AccessibilityCheckResolution.resolve(from: scratch.url) == .notConfigured)
        try Data(#"{"version": 1}"#.utf8).write(to: scratch.url.appending(path: AmooProjectConfig.fileName))
        #expect(AccessibilityCheckResolution.resolve(from: scratch.url) == .notConfigured)
        #expect(AccessibilityCheckResolution.notConfigured.policy.enabledChecks.isEmpty)
    }

    @Test("only checks set to true are enabled, in report order")
    func enabledChecksFollowTheFlags() throws {
        let scratch = try repository()
        defer { try? scratch.remove() }
        try Data("""
        {"version": 1, "accessibility": {
          "checks": {"contrast": true, "names": true, "traits": false},
          "configurations": {"large_text": true, "dark_mode": true}}}
        """.utf8).write(to: scratch.url.appending(path: AmooProjectConfig.fileName))
        let policy = AccessibilityCheckResolution.resolve(from: scratch.url).policy
        #expect(policy.enabledChecks == [.names, .contrast])
        #expect(policy.enabledConfigurations == [.darkMode, .largeText])
    }

    @Test("an unknown check name is an error, not silently ignored")
    func unknownNamesAreInvalid() throws {
        let scratch = try repository()
        defer { try? scratch.remove() }
        try Data(#"{"version": 1, "accessibility": {"checks": {"contrats": true}}}"#.utf8)
            .write(to: scratch.url.appending(path: AmooProjectConfig.fileName))
        guard case let .invalid(problem) = AccessibilityCheckResolution.resolve(from: scratch.url) else {
            Issue.record("Expected an invalid config")
            return
        }
        #expect(problem.contains("no check named 'contrats'"))
    }

    @Test("a nearer config overrides one check without restating the rest")
    func layeringMergesByName() throws {
        let root = try repository()
        defer { try? root.remove() }
        let platform = root.url.appending(path: "ios")
        try FileManager.default.createDirectory(at: platform, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "accessibility": {"checks": {"names": true, "contrast": true}}}"#.utf8)
            .write(to: root.url.appending(path: AmooProjectConfig.fileName))
        try Data(#"{"version": 1, "accessibility": {"checks": {"contrast": false}}}"#.utf8)
            .write(to: platform.appending(path: AmooProjectConfig.fileName))
        #expect(AccessibilityCheckResolution.resolve(from: platform).policy.enabledChecks == [.names])
    }

    @Test("writing the section keeps screenshots and profiles")
    func writeKeepsOtherSections() throws {
        let scratch = try repository()
        defer { try? scratch.remove() }
        let file = scratch.url.appending(path: AmooProjectConfig.fileName)
        try Data(#"{"version": 1, "screenshots": {"scale": 0.5}}"#.utf8).write(to: file)
        try AmooProjectConfig.writeAccessibilityChecks(
            AccessibilityCheckPolicy(checks: [.targetSize], configurations: [.darkMode]),
            to: file
        )
        let config = try AmooProjectConfig.load(file)
        #expect(config.screenshots?.scale == 0.5)
        #expect(config.accessibility?.enabledChecks == [.targetSize])
        #expect(config.accessibility?.enabledConfigurations == [.darkMode])
    }
}
