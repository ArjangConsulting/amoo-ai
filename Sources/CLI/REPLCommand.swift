import AmooCore
import Foundation

// MARK: - REPL startup options

struct REPLOptions {
    var port: Int
    var deviceHint: String?
    var platform: Platform?
}

func parseREPLOptions(args: [String]) -> REPLOptions {
    var port: Int?
    var deviceHint: String?
    var platform: Platform?
    var remaining = args

    while let first = remaining.first, first.hasPrefix("--") {
        switch first {
        case "--port":
            remaining.removeFirst()
            if let value = remaining.first, let parsed = Int(value) {
                port = parsed
                remaining.removeFirst()
            }
        case "--device":
            remaining.removeFirst()
            if let value = remaining.first {
                deviceHint = value
                remaining.removeFirst()
            }
        case "--platform":
            remaining.removeFirst()
            if let value = remaining.first {
                platform = Platform(rawValue: value.lowercased())
                remaining.removeFirst()
            }
        default:
            remaining.removeFirst()
        }
    }

    // Resolve default port based on explicit platform flag, or leave nil so REPL can
    // pick it up after device selection.
    let resolvedPort: Int = if let port {
        port
    } else if let platform {
        platform == .android ? 22088 : 22087
    } else {
        22087 // will be overridden after device selection when Android is chosen
    }

    return REPLOptions(port: resolvedPort, deviceHint: deviceHint, platform: platform)
}

// MARK: - REPL mode entry point

func startREPLMode(args: [String]) async {
    var options = parseREPLOptions(args: args)
    let selector = PlatformDeviceSelector()

    let device: AvailableDevice
    do {
        device = try await selector.selectDevice(hint: options.deviceHint, platform: options.platform)
    } catch let error as DeviceSelectionError {
        print(error.description)
        return
    } catch {
        print("Device selection failed: \(error)")
        return
    }

    // Adjust port to match the selected platform when the user didn't explicitly set one
    if options.deviceHint == nil, args.allSatisfy({ $0 != "--port" }) {
        switch device.platform {
        case .ios:
            options.port = 22087
        case .android:
            options.port = 22088
        }
    }

    await runREPL(device: device, port: options.port)
}
