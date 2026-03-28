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
        )
    ]
}
