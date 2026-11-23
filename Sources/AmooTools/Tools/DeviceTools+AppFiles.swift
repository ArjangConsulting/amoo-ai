extension DeviceTools {
    /// `device_pull_app_file`. Kept apart so the catalog enum stays under the type-length limit.
    static let pullAppFile = ToolDefinition(
        name: "device_pull_app_file",
        description: "Copy a file out of an installed app's own storage to the host, as evidence: a"
            + " network capture the app recorded, a log, a database. iOS simulator: any build. iOS"
            + " device: development-signed builds only. Android: container external for any build,"
            + " data for debuggable builds. Reports the local path and size.",
        properties: [
            "app_id": .init(type: "string", description: "The app's bundle identifier or package name"),
            "path": .init(
                type: "string",
                description: "Relative to the container's root, e.g. 'Documents/session.har' (iOS) or"
                    + " 'files/session.har' (Android). Absolute paths and '..' are refused."
            ),
            "container": .init(
                type: "string",
                description: "'data' (default): iOS data container, or Android /data/data/<package>."
                    + " 'external': Android /sdcard/Android/data/<package>."
            ),
            "output": .init(
                type: "string",
                description: "Local file to write. Defaults to the file's name in the current directory;"
                    + " a flow puts it in the run's output directory."
            ),
            "timeout_ms": .init(
                type: "string",
                description: "How long to wait for the file to appear, for an app that writes it"
                    + " asynchronously. Defaults to 0: a missing file fails at once."
            )
        ],
        required: ["app_id", "path"]
    )
}
