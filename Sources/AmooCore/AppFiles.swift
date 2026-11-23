import Foundation

/// Which part of an app's own storage a file is read from.
public enum AppStorageContainer: String, Sendable, Equatable, CaseIterable {
    /// The app's private data: on iOS its data container (`Documents`, `Library`, `tmp`), on Android
    /// its internal data directory (`/data/data/<package>`, read through `run-as` on a debuggable build).
    case data
    /// Android only: `/sdcard/Android/data/<package>`, which `adb` reads for any build.
    case external
}

/// A file in an app's storage to copy to the host.
public struct AppFileRequest: Sendable, Equatable {
    public var appID: String
    public var container: AppStorageContainer
    /// Relative to the container's root, such as `Documents/session.har` or `files/session.har`.
    public var path: String
    /// Where the copy is written on the host. Its parent directory is created, and a file already
    /// there is replaced.
    public var destination: URL

    /// Fails when `path` is empty, absolute or leaves the container through `..`, and when `appID`
    /// is not a bundle or package identifier.
    public init(appID: String, container: AppStorageContainer, path: String, destination: URL) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !appID.isEmpty, appID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw AppFileError.invalidPath(path, reason: "'\(appID)' is not a bundle or package identifier")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !path.hasPrefix("/") else {
            throw AppFileError.invalidPath(path, reason: "it must be relative to the app's storage root")
        }
        guard !components.isEmpty else {
            throw AppFileError.invalidPath(path, reason: "it names no file")
        }
        guard !components.contains("..") else {
            throw AppFileError.invalidPath(path, reason: "it must stay inside the app's storage")
        }
        self.appID = appID
        self.container = container
        self.path = components.joined(separator: "/")
        self.destination = destination
    }
}

/// A file copied out of an app's storage.
public struct PulledAppFile: Sendable, Equatable {
    /// The file as the device names it.
    public var devicePath: String
    public var localPath: String
    public var bytes: Int

    public init(devicePath: String, localPath: String, bytes: Int) {
        self.devicePath = devicePath
        self.localPath = localPath
        self.bytes = bytes
    }
}

public enum AppFileError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Nothing at `devicePath` yet; a caller may wait for the app to write it.
    case notFound(devicePath: String)
    /// The file or its container cannot be read from the host for this app or build.
    case unreadable(devicePath: String, reason: String)
    case invalidPath(String, reason: String)

    public var description: String {
        switch self {
        case let .notFound(devicePath):
            "No file at \(devicePath)."
        case let .unreadable(devicePath, reason):
            "Cannot read \(devicePath): \(reason)"
        case let .invalidPath(path, reason):
            "Invalid app file path '\(path)': \(reason)."
        }
    }
}

public extension AppFileRequest {
    /// Writes `data` to ``destination``, creating its directory and replacing an older file.
    func write(_ data: Data, devicePath: String) throws -> PulledAppFile {
        try prepareDestination()
        try data.write(to: destination)
        return PulledAppFile(devicePath: devicePath, localPath: destination.path, bytes: data.count)
    }

    /// Creates the destination's directory and removes a file already at the destination.
    func prepareDestination() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
    }

    /// The copy at ``destination`` once something else wrote it there.
    func pulled(devicePath: String) throws -> PulledAppFile {
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return PulledAppFile(devicePath: devicePath, localPath: destination.path, bytes: size)
    }
}

/// Copying files out of an app's own storage, part of ``AppManagement``.
public protocol AppFileTransfer: Sendable {
    /// Copies a file out of the app's storage to the host. Throws ``AppFileError/notFound(devicePath:)``
    /// when the file does not exist (yet).
    func pullAppFile(_ request: AppFileRequest) async throws -> PulledAppFile
}

public extension AppFileTransfer {
    func pullAppFile(_: AppFileRequest) async throws -> PulledAppFile {
        throw AmooError.unsupportedCapability(
            key: "app.files",
            reason: "This device cannot copy files out of an app's storage."
        )
    }
}
