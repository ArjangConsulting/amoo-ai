import Foundation

// MARK: - REPL startup options

struct REPLOptions {
    var port: Int
    var deviceHint: String?
}

func parseREPLOptions(args: [String]) -> REPLOptions {
    var port = 22087
    var deviceHint: String?
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
        default:
            remaining.removeFirst()
        }
    }

    return REPLOptions(port: port, deviceHint: deviceHint)
}

// MARK: - REPL mode entry point

func startREPLMode(args: [String]) async {
    let options = parseREPLOptions(args: args)
    let selector = DeviceSelector()

    let device: BootedDevice
    do {
        device = try await selector.selectDevice(hint: options.deviceHint)
    } catch let error as DeviceSelectionError {
        print(error.description)
        return
    } catch {
        print("Device selection failed: \(error)")
        return
    }

    let manager = CompanionManager()
    let config = CompanionConfig(
        port: options.port,
        deviceUDID: device.udid
    )

    do {
        try await manager.ensureRunning(config: config)
    } catch {
        print("Failed to install/start companion: \(error)")
        return
    }

    await runREPL(device: device, port: options.port, companionManager: manager)
}
