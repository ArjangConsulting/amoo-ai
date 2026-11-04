import AmooCore
import Foundation
import MCP

private struct DeviceCommandFlags {
    var platform: Platform = .ios
    var platformIsDefault = true
    var port: Int?
    var deviceID: String?
    var runtimeID: String?
    var json = false
}

// swiftlint:disable cyclomatic_complexity - one flat case per flag.
/// Consumes leading `--flag [value]` pairs from `remaining`, stopping at the first non-flag
/// token (the tool name).
private func parseDeviceFlags(remaining: inout [String]) -> Result<DeviceCommandFlags, DeviceCommandParseError> {
    var flags = DeviceCommandFlags()

    while let first = remaining.first, first.hasPrefix("--") {
        switch DeviceInvocationFlag(rawValue: first) {
        case .platform:
            remaining.removeFirst()
            guard let platformStr = remaining.first else {
                return .failure(.malformedArgument("--platform"))
            }
            guard let parsed = Platform(rawValue: platformStr.lowercased()) else {
                return .failure(.unknownPlatform(platformStr))
            }
            flags.platform = parsed
            flags.platformIsDefault = false
            remaining.removeFirst()

        case .port:
            remaining.removeFirst()
            guard let portStr = remaining.first else {
                return .failure(.invalidPort("(missing)"))
            }
            guard let parsed = Int(portStr) else {
                return .failure(.invalidPort(portStr))
            }
            flags.port = parsed
            remaining.removeFirst()

        case .device:
            remaining.removeFirst()
            guard let udid = remaining.first else {
                return .failure(.malformedArgument("--device (missing value)"))
            }
            flags.deviceID = udid
            remaining.removeFirst()

        case .runtimeID:
            remaining.removeFirst()
            guard let runtime = remaining.first, !runtime.hasPrefix("--") else {
                return .failure(.malformedArgument("--runtime-id (missing value)"))
            }
            flags.runtimeID = runtime
            remaining.removeFirst()

        case .json:
            remaining.removeFirst()
            flags.json = true

        case nil:
            // Must fail, not `break`: `break` only leaves the `switch`, so the `while` would spin
            // on the same token forever at 100% CPU.
            return .failure(.unknownFlag(first))
        }
    }

    return .success(flags)
}

// swiftlint:enable cyclomatic_complexity

// swiftlint:disable function_body_length cyclomatic_complexity
/// Parses `key=value` tool arguments plus repeatable `--env KEY=VALUE` / `--arg VALUE` flags
/// from the tokens following the tool name.
private func parseDeviceToolArguments(_ remaining: [String]) -> Result<[String: String], DeviceCommandParseError> {
    var arguments: [String: String] = [:]
    var envPairs: [String] = []
    var launchArgs: [String] = []

    var index = remaining.startIndex
    while index < remaining.endIndex {
        let arg = remaining[index]

        // `--env KEY=VALUE`, repeatable. Spelling environment variables as a tool argument means
        // writing `environment=KEY=VALUE`, whose two `=` read as a typo, and stacking several of
        // them into one comma-separated value makes it worse. Repeating a flag says what it means
        // and lets a value contain a comma.
        if arg == "--env" || arg == "--arg" {
            let valueIndex = remaining.index(after: index)
            guard valueIndex < remaining.endIndex else {
                return .failure(.malformedArgument("\(arg) (missing value)"))
            }
            let value = remaining[valueIndex]
            if arg == "--env" {
                guard value.contains("=") else {
                    return .failure(.malformedArgument("--env \(value) (expected KEY=VALUE)"))
                }
                envPairs.append(value)
            } else {
                launchArgs.append(value)
            }
            index = remaining.index(after: valueIndex)
            continue
        }

        if arg == "--arguments-json" {
            let valueIndex = remaining.index(after: index)
            guard valueIndex < remaining.endIndex else {
                return .failure(.malformedArgument("--arguments-json (missing object or @path)"))
            }
            do {
                let values = try parseStructuredDeviceArguments(remaining[valueIndex])
                guard arguments.keys.allSatisfy({ values[$0] == nil }) else {
                    return .failure(.malformedArgument("--arguments-json (duplicate argument)"))
                }
                arguments.merge(values, uniquingKeysWith: { _, value in value })
            } catch {
                return .failure(.malformedArgument("--arguments-json: \(error)"))
            }
            index = remaining.index(after: valueIndex)
            continue
        }

        let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            return .failure(.malformedArgument(arg))
        }
        guard arguments[String(parts[0])] == nil else {
            return .failure(.malformedArgument("\(parts[0]) (duplicate argument)"))
        }
        arguments[String(parts[0])] = String(parts[1])
        index = remaining.index(after: index)
    }

    // Newline-joined rather than comma-joined so a value may contain a comma; the parser accepts
    // either separator, keeping the comma form MCP clients already send. The trailing newline is
    // load-bearing: it marks the string as newline-separated even when there is a single pair,
    // which is otherwise indistinguishable from a comma-separated one and would see a lone value
    // like `LOCALES=en,fr,de` split back apart.
    if !envPairs.isEmpty {
        guard arguments["environment"] == nil else {
            return .failure(.malformedArgument("environment (duplicate --env and structured argument)"))
        }
        arguments["environment"] = envPairs.joined(separator: "\n") + "\n"
    }
    if !launchArgs.isEmpty {
        guard arguments["launch_args"] == nil else {
            return .failure(.malformedArgument("launch_args (duplicate --arg and structured argument)"))
        }
        arguments["launch_args"] = launchArgs.joined(separator: ",")
    }

    return .success(arguments)
}

// swiftlint:enable function_body_length cyclomatic_complexity

func parseDeviceCommandOptions(args: [String]) -> Result<DeviceCommandOptions, DeviceCommandParseError> {
    var remaining = args

    let flags: DeviceCommandFlags
    switch parseDeviceFlags(remaining: &remaining) {
    case let .success(parsed): flags = parsed
    case let .failure(error): return .failure(error)
    }

    guard let tool = remaining.first else {
        return .failure(.missingTool)
    }
    remaining.removeFirst()

    let arguments: [String: String]
    switch parseDeviceToolArguments(remaining) {
    case let .success(parsed): arguments = parsed
    case let .failure(error): return .failure(error)
    }

    return .success(DeviceCommandOptions(
        platform: flags.platform,
        port: flags.port ?? defaultPort(for: flags.platform),
        deviceID: normalizedDeviceID(flags.deviceID, for: flags.platform),
        tool: tool,
        arguments: arguments,
        runtimeID: flags.runtimeID,
        json: flags.json,
        portIsDefault: flags.port == nil,
        platformIsDefault: flags.platformIsDefault
    ))
}
