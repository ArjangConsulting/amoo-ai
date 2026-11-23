import AmooCore
import AmooLogging
import Foundation

private let logger = AmooLogger.forType(AppFileRequest.self)

extension DriverToolExecutor {
    /// `device_pull_app_file`: copies a file out of the app's storage, waiting up to `timeout_ms`
    /// for an app that writes it asynchronously.
    func executePullAppFile(driver: any PlatformDriver, arguments: [String: String]) async throws -> ToolResult {
        let request = try Self.appFileRequest(arguments: arguments)
        let appID = request.appID
        let container = request.container
        let waitMilliseconds = max(0, arguments["timeout_ms"].flatMap(Int.init) ?? 0)
        let deadline = ContinuousClock.now + .milliseconds(waitMilliseconds)
        logger.info("Pulling app file: container=\(container.rawValue) wait_ms=\(waitMilliseconds)")
        while true {
            do {
                let file = try await driver.pullAppFile(request)
                logger.info("Pulled app file: bytes=\(file.bytes)")
                return .success(
                    "Copied \(file.devicePath) to \(file.localPath) (\(file.bytes) bytes)",
                    structuredContent: .object([
                        "app_id": .string(appID), "container": .string(container.rawValue),
                        "device_path": .string(file.devicePath), "output": .string(file.localPath),
                        "bytes": .int(file.bytes)
                    ])
                )
            } catch let AppFileError.notFound(devicePath) {
                guard ContinuousClock.now < deadline else {
                    logger.error(
                        "App file not found",
                        error: AppFileError.notFound(devicePath: devicePath),
                        context: "feature=app_files action=pull wait_ms=\(waitMilliseconds)"
                    )
                    throw ToolExecutionError(
                        code: "file_not_found",
                        message: "No file at \(devicePath)"
                            + (waitMilliseconds > 0 ? " after waiting \(waitMilliseconds)ms." : ".")
                            + " Pass timeout_ms to wait for an app that writes it later.",
                        extra: ["device_path": .string(devicePath)]
                    )
                }
                try await Task.sleep(until: min(deadline, .now + .milliseconds(250)), clock: .continuous)
            } catch let AppFileError.unreadable(devicePath, reason) {
                logger.error(
                    "App file unreadable",
                    error: AppFileError.unreadable(devicePath: devicePath, reason: reason),
                    context: "feature=app_files action=pull container=\(container.rawValue)"
                )
                throw ToolExecutionError(
                    code: "file_unreadable",
                    message: "Cannot read \(devicePath): \(reason)",
                    extra: ["device_path": .string(devicePath)]
                )
            }
        }
    }

    /// The request `arguments` describe, or an `invalid_argument` error naming what is wrong.
    static func appFileRequest(arguments: [String: String]) throws -> AppFileRequest {
        guard let appID = arguments["app_id"], let path = arguments["path"] else {
            throw ToolExecutionError(code: "invalid_argument", message: "Missing required arguments: app_id, path")
        }
        let containerName = arguments["container"].flatMap { $0.isEmpty ? nil : $0 } ?? "data"
        guard let container = AppStorageContainer(rawValue: containerName.lowercased()) else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "container must be 'data' or 'external', not '\(containerName)'."
            )
        }
        do {
            return try AppFileRequest(
                appID: appID,
                container: container,
                path: path,
                destination: appFileDestination(output: arguments["output"], path: path)
            )
        } catch {
            throw ToolExecutionError(code: "invalid_argument", message: "\(error)")
        }
    }

    /// `output` as given, resolved against the current directory, or the pulled file's own name there.
    static func appFileDestination(output: String?, path: String) -> URL {
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let output, !output.isEmpty else {
            let name = path.split(separator: "/").last.map(String.init) ?? "app-file"
            return current.appending(path: name)
        }
        return URL(fileURLWithPath: (output as NSString).expandingTildeInPath, relativeTo: current).standardizedFileURL
    }
}
