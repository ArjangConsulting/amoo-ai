import Foundation
@testable import StudioProtocol
import TestCommons
import Testing

@Suite("amoo.config.json")
struct AmooProjectConfigTests {
    private func decode(_ json: String) throws -> AmooProjectConfig {
        try JSONDecoder().decode(AmooProjectConfig.self, from: Data(json.utf8))
    }

    private func load(_ json: String) throws -> AmooProjectConfig {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let file = scratch.url.appendingPathComponent(AmooProjectConfig.fileName)
        try Data(json.utf8).write(to: file)
        return try AmooProjectConfig.load(file)
    }

    @Test("decodes literal and keychain fields with their class")
    func decodesProfiles() throws {
        let config = try decode("""
        {"version": 1, "profiles": {"staging": {
          "apps": ["com.example.qa"], "requires_launch_env": {"API_ENV": "staging"},
          "fields": {
            "email": {"literal": "qa@example.test", "class": "identifier"},
            "password": {"keychain": {"service": "amoo.example", "account": "qa"}, "class": "secret"}
          }}}}
        """)
        let profile = try #require(config.profiles["staging"])
        #expect(profile.apps == ["com.example.qa"])
        #expect(profile.requiresLaunchEnv == ["API_ENV": "staging"])
        #expect(profile.fields["email"] == CredentialField(
            source: .literal("qa@example.test"),
            fieldClass: .identifier
        ))
        #expect(profile.fields["password"] == CredentialField(
            source: .keychain(service: "amoo.example", account: "qa"), fieldClass: .secret
        ))
    }

    @Test("a field needs exactly one source and a class", arguments: [
        #"{"class": "secret"}"#,
        #"{"literal": "a", "keychain": {"service": "s", "account": "a"}, "class": "secret"}"#,
        #"{"literal": "a"}"#,
        #"{"literal": "a", "class": "password"}"#
    ])
    func rejectsAmbiguousFields(field: String) {
        #expect(throws: (any Error).self) {
            try load(#"{"version": 1, "profiles": {"p": {"apps": ["a"], "fields": {"f": "# + field + #"}}}}"#)
        }
    }

    @Test("an env field names a variable, which must be a portable name")
    func environmentFields() throws {
        let config = try decode("""
        {"version": 1, "profiles": {"p": {"apps": ["a"],
          "fields": {"password": {"env": "QA_PASSWORD", "class": "secret"}}}}}
        """)
        #expect(config.profiles["p"]?.fields["password"]?.source == .environment("QA_PASSWORD"))
        let bad = AmooProjectConfig(profiles: ["p": CredentialProfile(apps: ["a"], fields: [
            "password": CredentialField(source: .environment("1-BAD"), fieldClass: .secret)
        ])])
        #expect(bad
            .validationProblems() == ["profile 'p' field 'password' names an invalid environment variable '1-BAD'"])
        #expect(throws: (any Error).self) {
            let field = #"{"env": "A", "literal": "b", "class": "secret"}"#
            try load(#"{"version": 1, "profiles": {"p": {"apps": ["a"], "fields": {"f": "# + field + "}}}}")
        }
    }

    @Test("validation names every problem")
    func validationProblems() {
        let config = AmooProjectConfig(version: 2, profiles: [
            "a#b": CredentialProfile(apps: [], fields: [:]),
            "kc": CredentialProfile(apps: ["x"], fields: [
                "pw": CredentialField(source: .keychain(service: "", account: "a"), fieldClass: .secret)
            ])
        ])
        let problems = config.validationProblems()
        #expect(problems.contains { $0.contains("version 2") })
        #expect(problems.contains { $0.contains("'a#b' must be non-empty") })
        #expect(problems.contains { $0.contains("lists no apps") })
        #expect(problems.contains { $0.contains("has no fields") })
        #expect(problems.contains { $0.contains("needs a keychain service and account") })
    }

    @Test("load reports the file and the problem")
    func loadErrorNamesTheFile() throws {
        let error = #expect(throws: AmooProjectConfigError.self) {
            try load(#"{"version": 1, "profiles": {"p": {"apps": [], "fields": {}}}}"#)
        }
        #expect(error?.description.contains(AmooProjectConfig.fileName) == true)
        #expect(error?.problem.contains("lists no apps") == true)
    }

    @Test("launch requirements accept a wildcard and name what is unmet")
    func launchRequirements() {
        let profile = CredentialProfile(
            apps: ["a"], requiresLaunchEnv: ["HOST": "*", "API_ENV": "staging"], fields: [:]
        )
        #expect(profile.unmetLaunchRequirements(["HOST": "10.0.2.2", "API_ENV": "staging"]).isEmpty)
        #expect(profile.unmetLaunchRequirements(["HOST": "x", "API_ENV": "prod"]) == ["API_ENV"])
        #expect(profile.unmetLaunchRequirements([:]) == ["API_ENV", "HOST"])
    }

    @Test("discovery walks up to the repository root and stops there")
    func discovery() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let repo = scratch.url.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("app/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        #expect(AmooProjectConfig.discover(from: nested) == nil)

        try Data(#"{"version": 1}"#.utf8).write(to: scratch.url.appendingPathComponent(AmooProjectConfig.fileName))
        #expect(AmooProjectConfig.discover(from: nested) == nil)

        let file = repo.appendingPathComponent(AmooProjectConfig.fileName)
        try Data(#"{"version": 1}"#.utf8).write(to: file)
        #expect(AmooProjectConfig.discover(from: nested)?.standardizedFileURL == file.standardizedFileURL)
    }

    @Test("an orchestrator config layers under a submodule's, and the inner one wins")
    func layeredDiscoveryInnerWins() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let root = scratch.url.appendingPathComponent("mobile")
        let ios = root.appendingPathComponent("iOS/App")
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try Data("gitdir: ../.git/modules/iOS".utf8)
            .write(to: root.appendingPathComponent("iOS/.git"))
        try Data("""
        {"version": 1, "profiles": {
          "qa": {"apps": ["com.app.ios", "com.app.android"], "requires_launch_env": {"A": "*", "B": "1"},
            "fields": {
              "email": {"literal": "shared@example.test", "class": "identifier"},
              "password": {"literal": "shared", "class": "identifier"}}},
          "prod": {"apps": ["com.app"], "fields": {"email": {"literal": "p@example.test", "class": "identifier"}}}}}
        """.utf8).write(to: root.appendingPathComponent(AmooProjectConfig.fileName))
        try Data("""
        {"version": 1, "profiles": {
          "qa": {"apps": ["com.app.ios"], "requires_launch_env": {"B": "2"},
            "fields": {"email": {"literal": "ios@example.test", "class": "identifier"}}}}}
        """.utf8).write(to: root.appendingPathComponent("iOS").appendingPathComponent(AmooProjectConfig.fileName))

        let files = AmooProjectConfig.discoverAll(from: ios)
        #expect(files.count == 2)
        #expect(files.first?.deletingLastPathComponent().lastPathComponent == "iOS")
        let config = try AmooProjectConfig.load(layers: files)
        let qa = try #require(config.profiles["qa"])
        #expect(qa.apps == ["com.app.ios"])
        #expect(qa.requiresLaunchEnv == ["A": "*", "B": "2"])
        #expect(qa.fields["email"]?.source == .literal("ios@example.test"))
        #expect(qa.fields["password"]?.source == .literal("shared"))
        #expect(config.profiles["prod"] != nil)

        let rootOnly = try AmooProjectConfig.load(layers: AmooProjectConfig.discoverAll(from: root))
        #expect(rootOnly.profiles["qa"]?.fields["email"]?.source == .literal("shared@example.test"))
    }
}
