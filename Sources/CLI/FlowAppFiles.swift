import Foundation

/// `device_pull_app_file` in a flow writes into the run's output directory: with no `output`, under
/// the file's own name, and a relative `output` is taken from there. An absolute `output` is kept.
/// Other tools' arguments pass through unchanged.
func flowOutputArguments(_ arguments: [String: String], tool: String, outputDirectory: URL?) -> [String: String] {
    guard tool == "device_pull_app_file", let outputDirectory else { return arguments }
    var forwarded = arguments
    let output = arguments["output"] ?? ""
    if output.isEmpty {
        let name = arguments["path"]?.split(separator: "/").last.map(String.init) ?? "app-file"
        forwarded["output"] = outputDirectory.appending(path: name).path
    } else if !output.hasPrefix("/"), !output.hasPrefix("~") {
        forwarded["output"] = outputDirectory.appending(path: output).path
    }
    return forwarded
}
