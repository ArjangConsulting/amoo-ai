public enum DeviceTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "device_boot",
            description: "Boot the simulator/emulator device"
        ),
        ToolDefinition(
            name: "device_shutdown",
            description: "Shut down the simulator/emulator device"
        ),
        ToolDefinition(
            name: "device_install_app",
            description: "Install an app on the device from a local path (.app or .apk)",
            properties: [
                "path": .init(type: "string", description: "Local file path to the app bundle (.app) or APK (.apk)")
            ],
            required: ["path"]
        ),
        ToolDefinition(
            name: "device_launch_app",
            description: "Launch an installed app by its bundle/package ID",
            properties: [
                "app_id": .init(
                    type: "string",
                    description: "The app's bundle identifier (iOS) or package name (Android)"
                ),
                "launch_args": .init(
                    type: "string",
                    description: "Comma-separated arguments passed to the app at launch (e.g. '-uitest,fast')"
                ),
                "environment": .init(
                    type: "string",
                    description: "Environment variables for the launched process, as KEY=VALUE"
                        + " pairs separated by commas — 'STAGE=test,VERBOSE=1' sets two. Newlines"
                        + " work as a separator too, for values that contain a comma. Environment"
                        + " is fixed at process start, so this only applies to this launch:"
                        + " relaunch the app to change it."
                ),
                "session_id": .init(
                    type: "string",
                    description: "Optional session id; routes the call to the session's driver"
                )
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "device_terminate_app",
            description: "Force-stop a running app by its bundle/package ID",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name")
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "device_uninstall_app",
            description: "Uninstall an app from the device",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name")
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "set_permission",
            description: "Grant or revoke an app permission (e.g. camera, location, notifications)",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name"),
                "permission": .init(type: "string", description: "Permission name (e.g. camera, location, photos)"),
                "granted": .init(
                    type: "string",
                    description: "Whether to grant (true) or revoke (false). Defaults to true."
                )
            ],
            required: ["app_id", "permission"]
        ),
        ToolDefinition(
            name: "set_location",
            description: "Simulate a GPS location on the device",
            properties: [
                "latitude": .init(type: "string", description: "Latitude as a decimal number"),
                "longitude": .init(type: "string", description: "Longitude as a decimal number")
            ],
            required: ["latitude", "longitude"]
        ),
        ToolDefinition(
            name: "clear_location",
            description: "Stop simulating GPS location"
        ),
        ToolDefinition(
            name: "set_appearance",
            description: "Set device appearance to light or dark mode",
            properties: [
                "appearance": .init(type: "string", description: "Appearance mode: light or dark")
            ],
            required: ["appearance"]
        ),
        ToolDefinition(
            name: "list_devices",
            title: "List Devices",
            description: "Enumerate booted simulators and online Android emulators/devices."
                + " Optionally filter by platform.",
            properties: [
                "platform": .init(
                    type: "string",
                    description: "Optional platform filter: 'ios' or 'android'. Omit for both."
                )
            ],
            outputSchema: ToolOutputSchema(
                properties: [
                    "devices": .init(
                        type: "array",
                        description: "Available devices",
                        items: .object(
                            properties: [
                                "id": .init(type: "string", description: "UDID or ADB serial"),
                                "name": .init(type: "string", description: "Device name"),
                                "platform": .init(type: "string", description: "ios or android"),
                                "os_version": .init(type: "string", description: "OS version when known"),
                                "state": .init(type: "string", description: "Device state, e.g. booted")
                            ],
                            required: ["id", "name", "platform", "os_version", "state"]
                        )
                    )
                ],
                required: ["devices"]
            )
        ),
        ToolDefinition(
            name: "list_apps",
            title: "List Apps",
            description: "List apps installed on the current session's device (or the default driver's device).",
            properties: [
                "session_id": .init(
                    type: "string",
                    description: "Optional session id; defaults to the server's default driver"
                )
            ],
            outputSchema: ToolOutputSchema(
                properties: [
                    "apps": .init(
                        type: "array",
                        description: "Installed apps",
                        items: .object(
                            properties: [
                                "app_id": .init(type: "string", description: "Bundle id or package name"),
                                "name": .init(type: "string", description: "Display name when known"),
                                "version": .init(type: "string", description: "Version string when known")
                            ],
                            required: ["app_id"]
                        )
                    )
                ],
                required: ["apps"]
            )
        )
    ]
}
