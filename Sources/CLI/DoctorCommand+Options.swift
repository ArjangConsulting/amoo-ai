import Foundation

struct DoctorOptions: Equatable {
    var json: Bool = false

    init() {}

    /// `--cli-only` is still accepted and ignored: it scoped the check away from MCP servers, which
    /// amoo no longer runs, and agent templates synced before that still pass it.
    init?(arguments: [String]) {
        for flag in arguments {
            switch flag {
            case "--json": json = true
            case "--cli-only": continue
            default: return nil
            }
        }
    }
}
