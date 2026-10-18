import AmooCore
import MCP
@testable import MCPServer
import TestSession
import XCTest

/// The launch configuration a repository profile (seeded by `amoo init --save`) supplies to a session.
extension MCPServerTests {
    private static let profile = #"""
    {"platform":"ios","launchArguments":["-AppleLanguages","(en)","-AppleLocale","en_US"],
     "launchEnvironment":{"OS_ACTIVITY_MODE":"disable","STAGE":"profile"}}
    """#

    private func startServer() -> (MCPServer, MockSessionBootstrapper) {
        let stack = makeSessionStack()
        let server = MCPServer(
            executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager),
            sessionManager: stack.manager
        )
        return (server, stack.bootstrapper)
    }

    func testStartSessionAppliesTheProfilesLaunchConfigurationWhenTheCallerPassesNone() async {
        let (server, bootstrapper) = startServer()
        let started = await server.execute(
            toolName: "start_session",
            arguments: ["app_id": "com.example", "context_json": Self.profile]
        )
        XCTAssertFalse(started.isError, started.content)
        XCTAssertEqual(started.structuredContent?.objectValue?["launch_config_source"], .string("profile"))
        let arguments = await bootstrapper.lastLaunchArguments
        let environment = await bootstrapper.lastLaunchEnvironment
        XCTAssertEqual(arguments, ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        XCTAssertEqual(environment, ["OS_ACTIVITY_MODE": "disable", "STAGE": "profile"])
    }

    func testExplicitLaunchArgumentsReplaceTheProfilesAndEnvironmentMergesKeyByKey() async {
        let (server, bootstrapper) = startServer()
        let started = await server.execute(
            toolName: "start_session",
            arguments: [
                "app_id": "com.example", "context_json": Self.profile,
                "launch_args": "-AppleLocale,fr_FR", "environment": "STAGE=explicit"
            ]
        )
        XCTAssertFalse(started.isError, started.content)
        XCTAssertEqual(started.structuredContent?.objectValue?["launch_config_source"], .string("explicit+profile"))
        let arguments = await bootstrapper.lastLaunchArguments
        let environment = await bootstrapper.lastLaunchEnvironment
        XCTAssertEqual(arguments, ["-AppleLocale", "fr_FR"], "the profile's arguments are not mixed in")
        XCTAssertEqual(environment, ["OS_ACTIVITY_MODE": "disable", "STAGE": "explicit"])
    }

    func testWithoutAProfileTheLaunchConfigurationIsTheCallers() async {
        let (server, bootstrapper) = startServer()
        let started = await server.execute(
            toolName: "start_session",
            arguments: ["app_id": "com.example", "launch_args": "-UITest", "environment": "A=1"]
        )
        XCTAssertEqual(started.structuredContent?.objectValue?["launch_config_source"], .string("explicit"))
        let arguments = await bootstrapper.lastLaunchArguments
        XCTAssertEqual(arguments, ["-UITest"])

        let (bareServer, _) = startServer()
        let bare = await bareServer.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        XCTAssertEqual(bare.structuredContent?.objectValue?["launch_config_source"], .string("none"))
    }
}
