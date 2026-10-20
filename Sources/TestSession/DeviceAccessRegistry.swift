import Foundation

/// In-process ownership of a device across asynchronous session bootstraps and cleanup.
/// Access is acquired before companion/app mutations and released only by its owner.
public actor DeviceAccessRegistry {
    private var owners: [String: UUID] = [:]

    public init() {}

    public func acquire(_ device: String) throws -> UUID {
        guard owners[device] == nil else { throw AccessError.busy }
        let owner = UUID()
        owners[device] = owner
        return owner
    }

    public func release(_ device: String, owner: UUID) {
        if owners[device] == owner {
            owners.removeValue(forKey: device)
        }
    }

    public enum AccessError: Error { case busy }
}
