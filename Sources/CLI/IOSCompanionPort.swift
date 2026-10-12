import Foundation

/// Chooses the TCP port an iOS session's companion listens on.
///
/// Every session used to share port 22087, so a second simulator could not be recorded while the
/// first was running, and any unrelated process holding the port broke `start_session` outright.
/// Android already gives each device its own port; this does the same for iOS.
enum IOSCompanionPort {
    /// The first port of the range per-device ports are derived into. It sits above Android's
    /// per-emulator block (`22088…22103`) and its free-port scan, which starts at `22104`.
    static let derivedBase = 23000
    /// How many ports the range holds. A UDID hashes to one slot, so two simulators collide with
    /// probability `1 / derivedSpan`; a collision is reported by the ownership check, not hidden.
    static let derivedSpan = 1000

    /// Ports a caller may request: unprivileged and inside the TCP range.
    static let allowedPorts = 1024 ... 65535

    /// A stable port for `udid`, so every process that targets the same simulator agrees on it and a
    /// companion left running by an earlier server is found again.
    ///
    /// FNV-1a over the uppercased UDID. `Hashable` is seeded per process, so it cannot be used here.
    static func derived(forUDID udid: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in udid.uppercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return derivedBase + Int(hash % UInt64(derivedSpan))
    }

    /// The port a long-lived host (the Studio service) gives an iOS device's companion: the one derived
    /// from a simulator's UDID so two devices can be driven at once, or the shared default for a
    /// device identifier that is not a simulator UDID (a physical device, `booted`).
    static func forDevice(_ identifier: String) -> Int {
        UUID(uuidString: identifier) != nil ? derived(forUDID: identifier) : CompanionConfig.defaultPort
    }

    /// Picks the port for a session on `udid`.
    ///
    /// In priority order: the `port` the caller passed to `start_session`, the `--port` the server
    /// was started with, a companion already listening on the legacy shared port for this very
    /// simulator (so one started with a plain `amoo companion start` is still adopted), and finally
    /// the port derived from the UDID.
    ///
    /// - Parameter legacyPortOwner: the simulator UDID served by whatever listens on
    ///   `CompanionConfig.defaultPort`, or `nil` if none or it cannot be determined.
    static func resolve(
        requested: Int?,
        serverDefault: Int?,
        udid: String,
        isPhysicalDevice: Bool,
        legacyPortOwner: () async -> String?
    ) async -> Int {
        if let requested {
            return requested
        }
        if let serverDefault {
            return serverDefault
        }
        if !isPhysicalDevice, let owner = await legacyPortOwner(),
           owner.caseInsensitiveCompare(udid) == .orderedSame {
            return CompanionConfig.defaultPort
        }
        return derived(forUDID: udid)
    }
}

/// Explains how to move a session's companion off a port that something else holds.
let companionPortAdvice = "Pass `port` to start_session, or start the server with"
    + " `amoo mcp serve --port <free-port>`, to use a different port."
