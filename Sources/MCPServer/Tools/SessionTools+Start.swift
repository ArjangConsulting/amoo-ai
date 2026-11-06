extension SessionTools {
    static let startSessionDefinition = ToolDefinition(
        name: "start_session",
        title: "Start Session",
        description: "Boot a device, ensure the companion is running, install + launch the app, and"
            + " return a session_id used to scope subsequent calls. Reinstall preserves app data by default;"
            + " fresh_install=true removes the app and its local data before installing build_path.",
        properties: [
            "app_id": .init(
                type: "string",
                description: "The app's bundle identifier (iOS) or package name (Android)"
            ),
            "platform": .init(
                type: "string",
                description: "Target platform: 'ios', 'android' or 'macos' (this Mac). Defaults to 'ios'."
            ),
            "device_hint": .init(
                type: "string",
                description: "Optional UDID/serial or name. Auto-selects when omitted."
            ),
            "port": .init(
                type: "string",
                description: "Optional TCP port for this session's companion (1024-65535). Defaults to"
                    + " the port `amoo mcp serve` was started with, else a stable per-device port, so"
                    + " sessions on different simulators/emulators can run at once. Set it to move off"
                    + " a port another process holds."
            ),
            "build_mode": .init(
                type: "string",
                description: "auto (default): use bundled/cached products, "
                    + "build missing/changed checkout products. "
                    + "reuse: never compile; fail if products are missing. "
                    + "rebuild: force companion compilation."
            ),
            "build_path": .init(
                type: "string",
                description: "Optional path to an .app bundle or .apk to install before launching."
                    + " Installs over any existing copy in place, preserving its data (auth session,"
                    + " onboarding state, etc.) — the same behavior as `simctl install`/`devicectl"
                    + " install`. Use fresh_install=true to remove the app and local data first."
            ),
            "fresh_install": .init(
                type: "boolean",
                description: "Remove the existing app and local data before installing. Requires build_path."
                    + " Does not clear external stores such as iOS Keychain or server data. Default false."
            ),
            "test_name": .init(
                type: "string",
                description: "Optional descriptive generated-test name, persisted with the session."
            ),
            "test_description": .init(
                type: "string",
                description: "Optional one-line description of the flow, persisted with the session"
                    + " and carried into the compiled plan."
            ),
            "context_path": .init(
                type: "string",
                description: "Optional path to test-context JSON or amoo.md with a fenced amoo-context"
                    + " JSON block (imports, baseClass,"
                    + " appFactory, harnessLaunchesApp, helpers, selectorExpressions). Persisted with"
                    + " the session so end_session and compile_session_to_plan fold it into the plan"
                    + " — the generated test then fits the host test target with no hand-editing."
            ),
            "context_json": .init(
                type: "string",
                description: "Inline test-context JSON, an alternative to context_path for callers"
                    + " that cannot pass a file path."
            ),
            "launch_args": .init(
                type: "string",
                description: "Comma-separated arguments passed to the app at launch. When omitted, the"
                    + " launchArguments of the discovered amoo.md / test context (locale and text size"
                    + " seeded by amoo init) apply; the result's launch_config_source says which."
            ),
            "environment": .init(
                type: "string",
                description: "Environment variables for the session's launch, as KEY=VALUE"
                    + " pairs separated by commas — 'UITEST=1,STAGE=test' sets two. Newlines"
                    + " work as a separator too, for values that contain a comma. Needed for"
                    + " apps that only enter a test mode via an environment flag, which must"
                    + " be present at launch to take effect."
            )
        ],
        required: ["app_id"],
        outputSchema: ToolOutputSchema(
            properties: [
                "session_id": .init(type: "string", description: "Identifier for the new session"),
                "owner": .init(type: "object", description: "Owning MCP process; live IDs cannot cross processes"),
                "app_id": .init(type: "string", description: "Bundle/package id"),
                "device_id": .init(type: "string", description: "Resolved device UDID or serial"),
                "platform": .init(type: "string", description: "ios or android"),
                "launch_config_source": .init(
                    type: "string",
                    description: "Where launch arguments/environment came from: explicit, profile,"
                        + " explicit+profile or none"
                ),
                "recording_health": .init(
                    type: "string",
                    description: "saved, failed, pending, unknown, or disabled"
                ),
                "warnings": .init(type: "array", description: "Startup warnings", items: .scalar(type: "string"))
            ],
            required: ["session_id", "app_id", "device_id", "platform"]
        )
    )
}
