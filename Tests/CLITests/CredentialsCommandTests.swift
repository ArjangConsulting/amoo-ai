@testable import CLI
import Foundation
import MCPServer
import StudioProtocol
import XCTest

/// `amoo credentials add|check` and the sign-in question in guided `amoo init`.
final class CredentialsCommandTests: InitTestCase {
    private func repository() throws -> URL {
        let root = try makeScratchDirectory().url
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        return root
    }

    private func config(in root: URL) throws -> AmooProjectConfig {
        try AmooProjectConfig.load(root.appendingPathComponent(AmooProjectConfig.fileName))
    }

    private func fileText(in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(AmooProjectConfig.fileName), encoding: .utf8)
    }

    // MARK: - add

    func testMockAccountIsSavedInTheConfigWithoutTouchingTheKeychain() async throws {
        let root = try repository()
        let writer = RecordingWriter()
        let prompter = ScriptedPrompter()
        // profile, app ids, identifier field, identifier, password, launch env
        prompter.asks = ["mock-user", "com.example.qa", "", "qa@example.test", "any-password", "AUTH_HOST"]
        prompter.choices = [0]

        let result = await runCredentialsAdd(prompter: prompter, defaults: .init(), root: root, store: writer)

        XCTAssertEqual(result.exitCode, 0, result.output)
        let profile = try XCTUnwrap(config(in: root).profiles["mock-user"])
        XCTAssertEqual(profile.apps, ["com.example.qa"])
        XCTAssertEqual(profile.requiresLaunchEnv, ["AUTH_HOST": "*"])
        XCTAssertEqual(
            profile.fields["email"],
            CredentialField(source: .literal("qa@example.test"), fieldClass: .identifier)
        )
        XCTAssertEqual(
            profile.fields["password"],
            CredentialField(source: .literal("any-password"), fieldClass: .secret)
        )
        let saves = await writer.saves
        XCTAssertTrue(saves.isEmpty)
        XCTAssertTrue(result.output.contains("credential=mock-user#password"))
        XCTAssertTrue(result.output.contains("amoo credentials add"))
        XCTAssertFalse(result.output.contains("any-password"))
    }

    func testRealAccountGoesToTheKeychainAndTheFileKeepsOnlyReferences() async throws {
        let root = try repository()
        let writer = RecordingWriter()
        let prompter = ScriptedPrompter()
        // profile, app ids, identifier field, identifier, password, repeat, launch env
        prompter.asks = [
            "staging-user", "com.example.qa", "username", "person@example.com", "Real-S3cret", "Real-S3cret",
            "API_ENV=staging"
        ]
        prompter.choices = [2]

        let result = await runCredentialsAdd(prompter: prompter, defaults: .init(), root: root, store: writer)

        XCTAssertEqual(result.exitCode, 0, result.output)
        let saves = await writer.saves
        XCTAssertEqual(saves.map(\.account), ["staging-user.username", "staging-user.password"])
        XCTAssertEqual(saves.map(\.service), ["amoo.com.example.qa", "amoo.com.example.qa"])
        let text = try fileText(in: root)
        XCTAssertFalse(text.contains("Real-S3cret"))
        XCTAssertFalse(text.contains("person@example.com"))
        let profile = try XCTUnwrap(config(in: root).profiles["staging-user"])
        XCTAssertEqual(profile.requiresLaunchEnv, ["API_ENV": "staging"])
        XCTAssertEqual(profile.fields["password"], CredentialField(
            source: .keychain(service: "amoo.com.example.qa", account: "staging-user.password"), fieldClass: .secret
        ))
        XCTAssertTrue(result.output.contains("amoo credentials check staging-user"))
    }

    func testMismatchedRealPasswordIsAskedAgain() async throws {
        let root = try repository()
        let writer = RecordingWriter()
        let prompter = ScriptedPrompter()
        prompter.asks = ["u", "com.example.qa", "", "a@b.c", "one", "two", "right", "right", ""]
        prompter.choices = [2]

        let result = await runCredentialsAdd(prompter: prompter, defaults: .init(), root: root, store: writer)

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(prompter.transcript.contains("The passwords did not match."))
        let saves = await writer.saves
        XCTAssertEqual(saves.last?.value, "right")
    }

    func testReplacingAProfileNeedsConsentAndDecliningChangesNothing() async throws {
        let root = try repository()
        try AmooProjectConfig(profiles: [
            "mock-user": CredentialProfile(apps: ["a"], fields: [
                "password": CredentialField(source: .literal("old"), fieldClass: .secret)
            ])
        ]).write(to: root.appendingPathComponent(AmooProjectConfig.fileName))
        let before = try fileText(in: root)
        let prompter = ScriptedPrompter()
        prompter.asks = ["mock-user"]
        prompter.confirms = [false]

        let result = await runCredentialsAdd(
            prompter: prompter,
            defaults: .init(),
            root: root,
            store: RecordingWriter()
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Cancelled"))
        XCTAssertEqual(try fileText(in: root), before)
    }

    func testWithoutAKeychainPlainTextAndEnvironmentAreOffered() async throws {
        let root = try repository()
        let prompter = ScriptedPrompter()
        prompter.asks = ["m", "com.example.qa", "", "qa@example.test", "pw", ""]
        prompter.choices = [0]

        let result = await runCredentialsAdd(
            prompter: prompter, defaults: .init(), root: root, store: RecordingWriter(isAvailable: false)
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        let menu = try XCTUnwrap(prompter.transcript.first { $0.hasPrefix("Where should this account's values live?") })
        XCTAssertTrue(menu.contains("Environment variables"))
        XCTAssertFalse(menu.contains("Keychain"))
        XCTAssertEqual(try config(in: root).profiles["m"]?.fields["password"]?.source, .literal("pw"))
    }

    func testEnvironmentAccountStoresOnlyVariableNames() async throws {
        let root = try repository()
        let writer = RecordingWriter()
        let prompter = ScriptedPrompter()
        // profile, app ids, identifier field, its variable (default), password variable, launch env
        prompter.asks = ["qa-user", "com.example.qa", "", "", "QA_PASSWORD", ""]
        prompter.choices = [1]

        let result = await runCredentialsAdd(prompter: prompter, defaults: .init(), root: root, store: writer)

        XCTAssertEqual(result.exitCode, 0, result.output)
        let profile = try XCTUnwrap(config(in: root).profiles["qa-user"])
        XCTAssertEqual(
            profile.fields["email"],
            CredentialField(source: .environment("AMOO_QA_USER_EMAIL"), fieldClass: .identifier)
        )
        XCTAssertEqual(
            profile.fields["password"],
            CredentialField(source: .environment("QA_PASSWORD"), fieldClass: .secret)
        )
        XCTAssertFalse(prompter.transcript.contains { $0.hasPrefix("Password") }, "no value is asked for")
        let saves = await writer.saves
        XCTAssertTrue(saves.isEmpty)
        XCTAssertTrue(result.output.contains("Set AMOO_QA_USER_EMAIL and QA_PASSWORD where amoo runs"))
    }

    func testEnvironmentVariableNamesAreSanitized() {
        XCTAssertEqual(environmentVariableName(profile: "qa-user.1", field: "email"), "AMOO_QA_USER_1_EMAIL")
    }

    func testAddRefusesWithoutATerminal() async throws {
        let root = try repository()
        let result = await handleCredentialsCommand(
            remaining: ["add"], isInteractive: { false }, prompter: ScriptedPrompter(), currentDirectory: root
        )
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("never accepts one as a flag or from an agent"))
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: root.appendingPathComponent(AmooProjectConfig.fileName).path))
    }

    // MARK: - check

    func testCheckReportsEachFieldWithoutItsValue() async throws {
        let root = try repository()
        try AmooProjectConfig(profiles: [
            "p": CredentialProfile(apps: ["a"], fields: [
                "email": CredentialField(source: .literal("qa@example.test"), fieldClass: .identifier),
                "found": CredentialField(source: .keychain(service: "s", account: "found"), fieldClass: .secret),
                "gone": CredentialField(source: .keychain(service: "s", account: "gone"), fieldClass: .secret),
                "shut": CredentialField(source: .keychain(service: "s", account: "shut"), fieldClass: .secret),
                "envset": CredentialField(source: .environment("QA_SET"), fieldClass: .secret),
                "envunset": CredentialField(source: .environment("QA_UNSET"), fieldClass: .secret)
            ])
        ]).write(to: root.appendingPathComponent(AmooProjectConfig.fileName))

        let result = await runCredentialsCheck(
            profile: "p", root: root, store: ScriptedStore(), environment: ["QA_SET": "value-of-env"]
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("p#email: literal in amoo.config.json"))
        XCTAssertTrue(result.output.contains("p#found: found in Keychain"))
        XCTAssertTrue(result.output.contains("p#gone: missing from Keychain"))
        XCTAssertTrue(result.output.contains("p#shut: locked"))
        XCTAssertTrue(result.output.contains("p#envset: QA_SET is set here"))
        XCTAssertTrue(result.output.contains("p#envunset: QA_UNSET is not set here"))
        XCTAssertFalse(result.output.contains("value-of"))
        XCTAssertFalse(result.output.contains("qa@example.test"))
    }

    func testLaunchRequirementsParse() {
        XCTAssertEqual(parseLaunchRequirements(""), [:])
        XCTAssertEqual(parseLaunchRequirements("A, B=x , C = y"), ["A": "*", "B": "x", "C": "y"])
    }

    // MARK: - Keychain timeout

    func testAKeychainReadThatNeverAnswersIsReportedLockedWithoutWaitingForIt() async {
        let started = ContinuousClock.now
        do {
            _ = try await withAbandonableTimeout(.milliseconds(100)) {
                try await Task.sleep(for: .seconds(30))
                return "late"
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SecretStoreError, .locked)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        let value = try? await withAbandonableTimeout(.seconds(5)) { "fast" }
        XCTAssertEqual(value, "fast")
    }
}

private actor RecordingWriter: CredentialWriting {
    struct Save: Equatable {
        var value: String
        var service: String
        var account: String
    }

    nonisolated let isAvailable: Bool
    private(set) var saves: [Save] = []

    init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    func save(_ value: String, service: String, account: String, label _: String) async throws {
        saves.append(Save(value: value, service: service, account: account))
    }
}

private struct ScriptedStore: SecretStore {
    func load(service _: String, account: String) async throws -> String {
        switch account {
        case "found": "value-of-found"
        case "gone": throw SecretStoreError.notFound
        default: throw SecretStoreError.locked
        }
    }
}

extension CredentialsCommandTests {
    func testAnOuterProfileIsOverriddenOnlyInTheNearestFile() async throws {
        let root = try repository()
        let outer = AmooProjectConfig(profiles: [
            "shared": CredentialProfile(apps: ["com.example.qa"], fields: [
                "password": CredentialField(source: .literal("outer"), fieldClass: .secret)
            ])
        ])
        try outer.write(to: root.appendingPathComponent(AmooProjectConfig.fileName))
        let platform = root.appendingPathComponent("android")
        try FileManager.default.createDirectory(at: platform, withIntermediateDirectories: true)
        try AmooProjectConfig().write(to: platform.appendingPathComponent(AmooProjectConfig.fileName))
        let prompter = ScriptedPrompter()
        prompter.asks = ["shared", "com.example.qa", "", "qa@example.test", "inner", ""]
        prompter.confirms = [true]
        prompter.choices = [0]

        let result = await runCredentialsAdd(
            prompter: prompter,
            defaults: .init(),
            root: platform,
            store: RecordingWriter()
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(prompter.transcript.contains { $0.contains("comes from an outer amoo.config.json") })
        XCTAssertEqual(try AmooProjectConfig.load(root.appendingPathComponent(AmooProjectConfig.fileName)), outer)
        let inner = try AmooProjectConfig.load(platform.appendingPathComponent(AmooProjectConfig.fileName))
        XCTAssertEqual(inner.profiles["shared"]?.fields["password"]?.source, .literal("inner"))
    }
}
