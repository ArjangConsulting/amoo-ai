import Foundation

extension InitManifest {
    static func decodeMigrating(_ data: Data) throws -> Self {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnvCommandParseError.usage("Invalid init manifest.")
        }
        let version = object["schemaVersion"] as? Int
        guard version == 1 || version == 2 else {
            throw EnvCommandParseError.usage("Unsupported init manifest version \(version.map(String.init) ?? "?").")
        }
        if version == 1, let results = object["results"] as? [[String: Any]] {
            object["results"] = results.map { entry in
                var migrated = entry
                if let id = migrated.removeValue(forKey: "lease") as? String {
                    migrated["runtime_id"] = DeviceRuntimeStore.normalizedID(id)
                }
                if let pid = migrated.removeValue(forKey: "holder_pid") {
                    migrated["companion_pid"] = pid
                }
                return migrated
            }
        }
        object["schemaVersion"] = 2
        return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
