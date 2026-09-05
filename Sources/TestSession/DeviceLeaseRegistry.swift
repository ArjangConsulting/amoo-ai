import Foundation

/// In-process ownership of a device across asynchronous session bootstraps and cleanup.
/// A lease is acquired before companion/app mutations and released only by its owner.
public actor DeviceLeaseRegistry {
    private var owners: [String: UUID] = [:]

    public init() {}

    public func acquire(_ device: String) throws -> UUID {
        guard owners[device] == nil else { throw LeaseError.busy }
        let owner = UUID()
        owners[device] = owner
        return owner
    }

    public func release(_ device: String, owner: UUID) {
        if owners[device] == owner {
            owners.removeValue(forKey: device)
        }
    }

    public enum LeaseError: Error { case busy }
}
