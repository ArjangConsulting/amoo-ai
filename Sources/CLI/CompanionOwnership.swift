import Foundation
import ProcessRunner

/// Which device a running companion serves, relative to the device a caller asked for.
///
/// A companion is just a gRPC server on a local port, and nothing in the protocol says which device
/// it drives. With two simulators booted, a companion started for one of them answers every query
/// sent to that port — so a caller targeting the other simulator gets back the wrong device's screen,
/// hierarchy, and foreground app, and every tap lands on the wrong device, all reported as success.
enum CompanionOwnership: Equatable {
    /// The companion serves the requested device, or no specific device was requested.
    case matches
    /// The companion's device could not be determined: a physical device behind `iproxy`, or a
    /// listener that could not be inspected. Callers keep their existing behavior.
    case unknown
    /// The companion serves a different simulator, so every query would reach the wrong device.
    case otherDevice(String)

    /// - Parameters:
    ///   - requested: The device the caller targets. `booted`, a device name, or a physical-device
    ///     identifier name nothing specific to compare against, so they always match.
    ///   - owner: The simulator UDID hosting the companion, if it could be resolved.
    init(requested: String, owner: String?) {
        guard let requestedUDID = UUID(uuidString: requested) else {
            self = .matches
            return
        }
        guard let owner, let ownerUDID = UUID(uuidString: owner) else {
            self = .unknown
            return
        }
        self = requestedUDID == ownerUDID ? .matches : .otherDevice(ownerUDID.uuidString)
    }
}

/// The UDID of the simulator hosting the companion listening on `port`, when it can be determined.
///
/// A simulator companion runs from inside its device's data container, so the listening process's
/// executable path names the device: `…/CoreSimulator/Devices/<UDID>/data/…`. That needs no
/// cooperation from a companion that is already running, which is what makes it usable against one
/// started by another `amoo` process or an older build. Returns `nil` for a physical device reached
/// through `iproxy`, on platforms without `lsof`, or when the listener cannot be inspected.
func companionSimulatorUDID(port: Int, processRunner: any ProcessRunner) async -> String? {
    // Absolute paths: MCP clients often spawn servers with a minimal PATH that omits /usr/sbin.
    guard let listing = try? await processRunner.run([
        "/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"
    ]),
        listing.exitCode == 0,
        let pid = listenerPID(fromLsofOutput: listing.stdout),
        let command = try? await processRunner.run(["/bin/ps", "-p", String(pid), "-o", "comm="]),
        command.exitCode == 0
    else { return nil }
    return simulatorUDID(inExecutablePath: command.stdout)
}

/// The first process ID in `lsof -F p` field output, where each process record starts `p<pid>`.
func listenerPID(fromLsofOutput output: String) -> Int32? {
    output.split(whereSeparator: \.isNewline)
        .lazy
        .compactMap { line -> Int32? in
            guard line.first == "p" else { return nil }
            return Int32(line.dropFirst())
        }
        .first
}

/// The device UDID in a path under `CoreSimulator/Devices/<UDID>/`, uppercased as simctl reports it.
func simulatorUDID(inExecutablePath path: String) -> String? {
    let components = path.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
    for index in components.indices.dropFirst() where components[index] == "Devices" {
        guard components[index - 1] == "CoreSimulator", index + 1 < components.endIndex,
              let udid = UUID(uuidString: String(components[index + 1]))
        else { continue }
        return udid.uuidString
    }
    return nil
}

/// Refuses to reuse a companion that serves a different simulator than `config` targets.
///
/// A companion this process did not start can be serving any booted simulator. Reusing one attached
/// to another device would drive that device for the whole session while every call reported
/// success, so fail loudly instead.
func refuseOtherSimulatorsCompanion(config: CompanionConfig, processRunner: any ProcessRunner) async throws {
    let owner = await companionSimulatorUDID(port: config.port, processRunner: processRunner)
    if case let .otherDevice(owner) = CompanionOwnership(requested: config.deviceUDID, owner: owner) {
        throw CompanionError.launchFailed(
            companionMismatchMessage(port: config.port, requested: config.deviceUDID, owner: owner)
        )
    }
}

/// Explains a companion/device mismatch and how to target the requested device instead.
func companionMismatchMessage(port: Int, requested: String, owner: String) -> String {
    """
    The companion on port \(port) is attached to simulator \(owner), not \(requested). \
    Every query and gesture would reach \(owner) while reporting success.
    To target \(requested), stop that companion, or run one for it on a free port and use that port:
      amoo companion start --platform ios --device \(requested) --port <free-port> --app <bundle-id>
      amoo device --device \(requested) --port <free-port> <tool> ...
    """
}
