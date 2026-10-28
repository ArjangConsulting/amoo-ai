import Foundation

struct DoctorOptions: Equatable {
    var json: Bool = false
    var killStale: Bool = false
    var cliOnly: Bool = false
    var mcpPID: Int32?

    init() {}

    init?(arguments: [String]) {
        var remaining = arguments[...]
        while let flag = remaining.popFirst() {
            switch flag {
            case "--json": json = true
            case "--kill-stale": killStale = true
            case "--cli-only": cliOnly = true
            case "--mcp-pid":
                guard mcpPID == nil, let value = remaining.popFirst(), let pid = Int32(value), pid > 0 else {
                    return nil
                }
                mcpPID = pid
            default: return nil
            }
        }
        guard !cliOnly || (mcpPID == nil && !killStale) else { return nil }
    }

    func includesMCPServer(_ pid: Int32) -> Bool {
        !cliOnly && (mcpPID == nil || mcpPID == pid)
    }
}
