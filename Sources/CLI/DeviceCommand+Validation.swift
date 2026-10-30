import MCPServer

/// Rejects argument keys the tool does not declare, naming the ones it does.
///
/// Tools read the keys they know and ignore the rest, so a misspelt or guessed key — `query=`
/// for `find_elements` — ran the call unfiltered and returned every element on screen, which
/// reads like a real answer. `nil` when the call is fine or amoo has no schema for the tool (the
/// executor reports unknown tools itself).
func unknownArgumentMessage(tool: String, arguments: [String: String]) -> String? {
    guard let definition = MCPServer().toolDefinitions().first(where: { $0.name == tool }) else {
        return nil
    }
    let unknown = Set(arguments.keys).subtracting(definition.properties.keys).sorted()
    guard !unknown.isEmpty else { return nil }
    let accepted = definition.properties.keys.filter { $0 != "session_id" }.sorted()
    let noun = unknown.count == 1 ? "argument" : "arguments"
    return "Unknown \(noun) for \(tool): \(unknown.joined(separator: ", ")). "
        + (accepted.isEmpty ? "It takes no arguments." : "Accepted: \(accepted.joined(separator: ", ")).")
}
