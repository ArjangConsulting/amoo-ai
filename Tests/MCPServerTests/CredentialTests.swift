import AmooCore
import Foundation
import MCP
@testable import MCPServer
@testable import SessionCompiler
import StudioProtocol
import TestCommons
import TestSession
import XCTest

/// `credential="<profile>#<field>"`: amoo types a value the caller never sees, only into an app and
/// launch environment the profile allows, only into a secure field when it is a secret, and the
/// value never comes back out of amoo.
final class CredentialTests: XCTestCase {
    private static let canary = "canary-SECRET-7731"
    private static let appID = "com.example.app"
    private static let authKey = "FIREBASE_AUTH_EMULATOR_HOST"

    private var scratch: TemporaryDirectory?

    override func setUpWithError() throws {
        scratch = try TemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try scratch?.remove()
    }

    private func writeConfig(_ json: String) throws -> URL {
        let file = try XCTUnwrap(scratch).url.appendingPathComponent(AmooProjectConfig.fileName)
        try Data(json.utf8).write(to: file)
        return file
    }

    private func mockConfig(password: String = "{ \"literal\": \"canary-SECRET-7731\", \"class\": \"secret\" }")
        throws -> URL {
        try writeConfig("""
        {
          "version": 1,
          "profiles": {
            "mock-user": {
              "apps": ["\(Self.appID)"],
              "requires_launch_env": { "\(Self.authKey)": "*" },
              "fields": {
                "email": { "literal": "qa@example.test", "class": "identifier" },
                "password": \(password)
              }
            }
          }
        }
        """)
    }

    private func executor(
        _ driver: CredentialDriver,
        config: URL?,
        store: any SecretStore = UnavailableSecretStore(),
        sessionManager: SessionManager? = nil
    ) -> DriverToolExecutor {
        DriverToolExecutor(
            driver: driver,
            sessionManager: sessionManager,
            credentialResolver: CredentialResolver(locateConfigs: { [config].compactMap(\.self) }, store: store)
        )
    }

    private func launched(_ executor: DriverToolExecutor, app: String = appID, environment: [String: String]? = nil)
        async {
        await executor.recordCredentialLaunch(appID: app, environment: environment ?? [Self.authKey: "10.0.2.2:9099"])
    }

    private func code(_ result: ToolResult) -> String? {
        result.structuredContent?.objectValue?["code"]?.stringValue
    }

    // MARK: - Filling

    func testSecretFillsASecureFieldAndNeverComesBack() async throws {
        let driver = CredentialDriver(secure: true)
        let executor = try executor(driver, config: mockConfig())
        await launched(executor)

        let result = await executor.execute(
            toolName: "fill_field", arguments: ["id": "field", "credential": "mock-user#password"]
        )

        XCTAssertFalse(result.isError, result.content)
        let typed = await driver.typed
        XCTAssertEqual(typed, [Self.canary])
        XCTAssertTrue(result.content.contains("a credential"))
        XCTAssertFalse(result.content.contains(Self.canary))
        XCTAssertNil(result.structuredContent?.objectValue?["value_length"])
        XCTAssertFalse("\(String(describing: result.structuredContent))".contains(Self.canary))
    }

    func testIdentifierFillsAnyFieldAndStaysVisible() async throws {
        let driver = CredentialDriver(secure: false)
        let executor = try executor(driver, config: mockConfig())
        await launched(executor)

        let result = await executor.execute(
            toolName: "set_text", arguments: ["id": "field", "credential": "mock-user#email"]
        )

        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["verification_mode"]?.stringValue, "exact")
        let typed = await driver.typed
        XCTAssertEqual(typed, ["qa@example.test"])
    }

    func testSecretIsRefusedForAFieldThatIsNotSecure() async throws {
        let driver = CredentialDriver(secure: false)
        let executor = try executor(driver, config: mockConfig())
        await launched(executor)

        let result = await executor.execute(
            toolName: "fill_field", arguments: ["id": "field", "credential": "mock-user#password"]
        )

        XCTAssertTrue(result.isError)
        XCTAssertEqual(code(result), "credential_field_not_secure")
        let typed = await driver.typed
        XCTAssertTrue(typed.isEmpty)
    }

    func testSecretIsRefusedForTypeTextBecauseTheTargetCannotBeChecked() async throws {
        let driver = CredentialDriver(secure: true)
        let executor = try executor(driver, config: mockConfig())
        await launched(executor)

        let result = await executor.execute(toolName: "type_text", arguments: ["credential": "mock-user#password"])

        XCTAssertEqual(code(result), "credential_field_not_secure")
        let typed = await driver.typed
        XCTAssertTrue(typed.isEmpty)
    }

    func testIdentifierCanBeTypedIntoTheFocusedField() async throws {
        let driver = CredentialDriver(secure: false)
        let executor = try executor(driver, config: mockConfig())
        await launched(executor)

        let result = await executor.execute(toolName: "type_text", arguments: ["credential": "mock-user#email"])

        XCTAssertFalse(result.isError, result.content)
        let typed = await driver.typed
        XCTAssertEqual(typed, ["qa@example.test"])
    }

    // MARK: - Gate

    func testGateRefusesBeforeAnyValueIsTyped() async throws {
        let config = try mockConfig()
        let cases = [
            GateCase(
                name: "wrong app",
                environment: [Self.authKey: "x"],
                app: "com.other.app",
                reference: "mock-user#password",
                expected: "credential_not_allowed"
            ),
            GateCase(
                name: "missing launch env",
                environment: [:],
                reference: "mock-user#password",
                expected: "credential_not_allowed"
            ),
            GateCase(name: "unknown profile", reference: "nobody#password", expected: "no_credentials"),
            GateCase(name: "unknown field", reference: "mock-user#pin", expected: "no_credentials")
        ]
        for gate in cases {
            let (name, environment, app, reference, expected) = (
                gate.name, gate.environment, gate.app, gate.reference, gate.expected
            )
            let driver = CredentialDriver(secure: true)
            let executor = executor(driver, config: config)
            await launched(executor, app: app ?? Self.appID, environment: environment)
            let result = await executor.execute(
                toolName: "fill_field", arguments: ["id": "field", "credential": reference]
            )
            XCTAssertEqual(code(result), expected, name)
            XCTAssertEqual(result.structuredContent?.objectValue?["blocked"], .bool(true), name)
            let typed = await driver.typed
            XCTAssertTrue(typed.isEmpty, name)
        }
    }

    func testMissingLaunchEnvironmentNamesTheKey() async throws {
        let executor = try executor(CredentialDriver(secure: true), config: mockConfig())
        await launched(executor, environment: [:])
        let result = await executor.execute(
            toolName: "fill_field", arguments: ["id": "field", "credential": "mock-user#password"]
        )
        XCTAssertTrue(result.content.contains(Self.authKey))
        XCTAssertTrue(result.content.hasPrefix("blocked: profile not allowed for \(Self.appID)"))
    }

    func testNoLaunchRecordIsRefused() async throws {
        let executor = try executor(CredentialDriver(secure: true), config: mockConfig())
        let result = await executor.execute(
            toolName: "fill_field", arguments: ["id": "field", "credential": "mock-user#password"]
        )
        XCTAssertEqual(code(result), "credential_not_allowed")
    }

    func testNoConfigIsBlockedWithoutCredentials() async {
        let executor = executor(CredentialDriver(secure: true), config: nil)
        await launched(executor)
        let result = await executor.execute(
            toolName: "fill_field", arguments: ["id": "field", "credential": "mock-user#password"]
        )
        XCTAssertEqual(code(result), "no_credentials")
        XCTAssertTrue(result.content.hasPrefix("blocked: no credentials"))
    }

    func testKeychainFieldsMapStoreFailuresToBlockedResults() async throws {
        let keychain = "{ \"keychain\": { \"service\": \"amoo.test\", \"account\": \"pw\" }, \"class\": \"secret\" }"
        let config = try mockConfig(password: keychain)
        let cases: [(any SecretStore, String)] = [
            (UnavailableSecretStore(), "credential_store_unavailable"),
            (FailingStore(error: .locked), "credential_store_locked"),
            (FailingStore(error: .notFound), "no_credentials")
        ]
        for (store, expected) in cases {
            let executor = executor(CredentialDriver(secure: true), config: config, store: store)
            await launched(executor)
            let result = await executor.execute(
                toolName: "fill_field", arguments: ["id": "field", "credential": "mock-user#password"]
            )
            XCTAssertEqual(code(result), expected)
        }
    }

    func testKeychainValueIsTypedWhenTheStoreHasIt() async throws {
        let keychain = "{ \"keychain\": { \"service\": \"amoo.test\", \"account\": \"pw\" }, \"class\": \"secret\" }"
        let driver = CredentialDriver(secure: true)
        let executor = try executor(
            driver,
            config: mockConfig(password: keychain),
            store: FixedStore(value: "kc-value")
        )
        await launched(executor)
        let result = await executor.execute(
            toolName: "fill_field", arguments: ["id": "field", "credential": "mock-user#password"]
        )
        XCTAssertFalse(result.isError, result.content)
        let typed = await driver.typed
        XCTAssertEqual(typed, ["kc-value"])
    }

    func testLaunchThroughAmooIsWhatTheGateChecks() async {
        let executor = executor(CredentialDriver(secure: true), config: nil)
        await executor.noteLaunch(
            toolName: "device_launch_app",
            arguments: ["app_id": Self.appID, "environment": "\(Self.authKey)=10.0.2.2:9099,MODE=qa"],
            result: .success("launched")
        )
        let launch = await executor.credentialLaunch(sessionID: nil)
        XCTAssertEqual(launch, CredentialLaunch(
            appID: Self.appID, environment: [Self.authKey: "10.0.2.2:9099", "MODE": "qa"]
        ))
        await executor.noteLaunch(
            toolName: "device_launch_app", arguments: ["app_id": "com.failed"], result: .error("no")
        )
        let unchanged = await executor.credentialLaunch(sessionID: nil)
        XCTAssertEqual(unchanged?.appID, Self.appID)
    }

    // MARK: - Arguments

    func testArgumentRulesAreEnforcedBeforeResolving() async throws {
        let config = try mockConfig()
        let cases: [(String, [String: String])] = [
            ("fill_field", ["id": "field", "value": "x", "credential": "mock-user#password"]),
            ("fill_field", ["id": "field", "record_value": "fixture", "credential": "mock-user#email"]),
            ("tap_element", ["id": "field", "credential": "mock-user#email"]),
            ("fill_field", ["id": "field", "credential": "mock-user"]),
            ("fill_field", ["id": "field", "credential": "#password"])
        ]
        for (tool, arguments) in cases {
            let driver = CredentialDriver(secure: true)
            let executor = executor(driver, config: config)
            await launched(executor)
            let result = await executor.execute(toolName: tool, arguments: arguments)
            XCTAssertEqual(code(result), "invalid_argument", "\(tool) \(arguments)")
            let typed = await driver.typed
            XCTAssertTrue(typed.isEmpty)
        }
    }

    func testSchemasOfferCredentialAndNoLongerRequireAValue() {
        let tools = MCPServer().toolDefinitions().filter { ["type_text", "set_text", "fill_field"].contains($0.name) }
        XCTAssertEqual(tools.count, 3)
        for tool in tools {
            XCTAssertNotNil(tool.properties["credential"], tool.name)
            XCTAssertFalse(tool.required.contains("value"), tool.name)
            XCTAssertFalse(tool.required.contains("text"), tool.name)
        }
    }

    // MARK: - Scrubbing

    func testADriverErrorThatEchoesTheSecretIsScrubbed() async throws {
        let driver = CredentialDriver(secure: true, echoInError: true)
        let executor = try executor(driver, config: mockConfig())
        await launched(executor)
        let result = await executor.execute(
            toolName: "fill_field", arguments: ["id": "field", "credential": "mock-user#password"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.content.contains(Self.canary))
        XCTAssertTrue(result.content.contains("<redacted>"))
    }

    func testLaterResultsShowingTheSecretAreScrubbed() async throws {
        let driver = CredentialDriver(secure: true)
        let executor = try executor(driver, config: mockConfig())
        await launched(executor)
        _ = await executor.execute(
            toolName: "fill_field",
            arguments: ["id": "field", "credential": "mock-user#password"]
        )

        let found = await executor.execute(toolName: "find_elements", arguments: ["id": "revealed"])

        XCTAssertFalse(found.content.contains(Self.canary), found.content)
        XCTAssertFalse("\(String(describing: found.structuredContent))".contains(Self.canary))
    }

    func testRecordedSessionReportAndPlanNeverContainTheSecret() async throws {
        let driver = CredentialDriver(secure: true)
        let manager = SessionManager(bootstrapper: CredentialBootstrapper(driver: driver))
        let session = try await manager.startSession(
            appID: Self.appID, platform: .android, environment: [Self.authKey: "10.0.2.2:9099"]
        )
        let executor = try executor(driver, config: mockConfig(), sessionManager: manager)

        let result = await executor.execute(
            toolName: "fill_field",
            arguments: ["id": "field", "credential": "mock-user#password", "session_id": session.id]
        )
        XCTAssertFalse(result.isError, result.content)

        let report = await SessionReport.make(from: session)
        let reportJSON = try XCTUnwrap(String(bytes: SessionReport.makeJSONEncoder().encode(report), encoding: .utf8))
        XCTAssertFalse(reportJSON.contains(Self.canary))
        let recorded = report.actions.first { $0.toolName == "fill_field" }
        XCTAssertEqual(recorded?.arguments["credential"], "mock-user#password")
        XCTAssertEqual(recorded?.arguments["value"], "<redacted, credential>")

        let plan = try SessionPlanCompiler.compile(report: report, testName: "SignIn", testDescription: nil)
        let planJSON = try XCTUnwrap(String(bytes: JSONEncoder().encode(plan), encoding: .utf8))
        XCTAssertFalse(planJSON.contains(Self.canary))
        XCTAssertTrue(plan.warnings.contains { $0.kind == .redacted })
        try await manager.endSession(session.id)
    }
}

private struct GateCase {
    var name: String
    var environment: [String: String]?
    var app: String?
    var reference: String
    var expected: String
}

private struct FailingStore: SecretStore {
    let error: SecretStoreError

    func load(service _: String, account _: String) async throws -> String {
        throw error
    }
}

private struct FixedStore: SecretStore {
    let value: String

    func load(service _: String, account _: String) async throws -> String {
        value
    }
}

private struct EchoError: Error, CustomStringConvertible {
    let text: String

    var description: String {
        "companion rejected input '\(text)'"
    }
}

private struct CredentialBootstrapper: SessionBootstrapper {
    let driver: CredentialDriver

    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult {
        BootstrapResult(driver: driver, deviceID: "emulator-5554", platform: request.platform, cleanup: {})
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        []
    }
}

/// One text field. A secure field reads back as bullets once filled, like a real password field.
private actor CredentialDriver: PlatformDriver {
    private let secure: Bool
    private let echoInError: Bool
    private(set) var typed: [String] = []

    init(secure: Bool, echoInError: Bool = false) {
        self.secure = secure
        self.echoInError = echoInError
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        let last = typed.last ?? ""
        if selector.id == "revealed" {
            return [ElementInfo(id: "revealed", label: "Password \(last)", value: last)]
        }
        let value = secure ? String(repeating: "•", count: last.count) : last
        return [ElementInfo(id: "field", label: "Field", value: value, isSecureTextEntry: secure)]
    }

    func setText(_: ElementSelector, text: String) async throws {
        if echoInError {
            throw EchoError(text: text)
        }
        typed.append(text)
    }

    func typeText(_ text: String) async throws {
        typed.append(text)
    }
}
